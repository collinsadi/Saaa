package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Usage is what one request, or one account's month, cost in tokens and
// money. Numbers only: the meter never sees or keeps content.
type Usage struct {
	Requests           int64 `json:"requests"`
	InputTokens        int64 `json:"input_tokens"`
	OutputTokens       int64 `json:"output_tokens"`
	CacheReadTokens    int64 `json:"cache_read_tokens"`
	CacheWrite5mTokens int64 `json:"cache_write_5m_tokens"`
	CacheWrite1hTokens int64 `json:"cache_write_1h_tokens"`
	CostMicros         int64 `json:"cost_micros"`
}

func (u *Usage) add(other Usage) {
	u.Requests += other.Requests
	u.InputTokens += other.InputTokens
	u.OutputTokens += other.OutputTokens
	u.CacheReadTokens += other.CacheReadTokens
	u.CacheWrite5mTokens += other.CacheWrite5mTokens
	u.CacheWrite1hTokens += other.CacheWrite1hTokens
	u.CostMicros += other.CostMicros
}

// period is the calendar month in UTC, like "2026-10".
func period(t time.Time) string { return t.UTC().Format("2006-01") }

// periodEnd is when the month containing t ends, in UTC.
func periodEnd(t time.Time) time.Time {
	start := time.Date(t.UTC().Year(), t.UTC().Month(), 1, 0, 0, 0, 0, time.UTC)
	return start.AddDate(0, 1, 0)
}

type meterFile struct {
	Version int                          `json:"version"`
	Usage   map[string]map[string]*Usage `json:"usage"` // account id -> period -> totals
}

// Meter keeps per-account monthly totals in memory and in data/usage.json
// (mode 0600, written atomically when it changed).
type Meter struct {
	mu    sync.Mutex
	path  string
	usage map[string]map[string]*Usage
	dirty bool
}

func OpenMeter(dataDir string) (*Meter, error) {
	m := &Meter{path: filepath.Join(dataDir, "usage.json"), usage: map[string]map[string]*Usage{}}
	raw, err := os.ReadFile(m.path)
	if errors.Is(err, os.ErrNotExist) {
		return m, nil
	}
	if err != nil {
		return nil, err
	}
	var file meterFile
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, err
	}
	if file.Version != 1 {
		return nil, errStoreVersion
	}
	if file.Usage != nil {
		m.usage = file.Usage
	}
	return m, nil
}

func (m *Meter) Record(accountID string, at time.Time, u Usage) {
	m.mu.Lock()
	defer m.mu.Unlock()
	months, ok := m.usage[accountID]
	if !ok {
		months = map[string]*Usage{}
		m.usage[accountID] = months
	}
	key := period(at)
	total, ok := months[key]
	if !ok {
		total = &Usage{}
		months[key] = total
	}
	total.add(u)
	m.dirty = true
}

// Month is an account's totals for the month containing at.
func (m *Meter) Month(accountID string, at time.Time) Usage {
	m.mu.Lock()
	defer m.mu.Unlock()
	if total, ok := m.usage[accountID][period(at)]; ok {
		return *total
	}
	return Usage{}
}

func (m *Meter) Forget(accountID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.usage[accountID]; ok {
		delete(m.usage, accountID)
		m.dirty = true
	}
}

func (m *Meter) FlushIfDirty() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.dirty {
		return nil
	}
	raw, err := json.MarshalIndent(meterFile{Version: 1, Usage: m.usage}, "", "  ")
	if err != nil {
		return err
	}
	if err := writeFileAtomic(m.path, raw, 0o600); err != nil {
		return err
	}
	m.dirty = false
	return nil
}

// usageScanner reads token counts from a reply as it streams past, without
// holding it back: for server-sent events it looks only at message_start
// and message_delta, whose usage blocks carry counts and never content;
// for a JSON reply it reads the top-level usage once the body is complete.
// Anything else is skipped without being parsed or kept.
type usageScanner struct {
	stream  bool
	line    []byte
	event   string
	body    []byte
	model   string
	usage   Usage
	sawAny  bool
	skipped bool // the current line outgrew maxLine and is being skipped
}

const (
	maxLine     = 64 << 10
	maxJSONBody = 4 << 20
)

func newUsageScanner(contentType string) *usageScanner {
	return &usageScanner{stream: bytes.HasPrefix([]byte(contentType), []byte("text/event-stream"))}
}

func (s *usageScanner) Write(p []byte) {
	if !s.stream {
		if len(s.body)+len(p) <= maxJSONBody {
			s.body = append(s.body, p...)
		} else {
			s.skipped = true
		}
		return
	}
	for len(p) > 0 {
		newline := bytes.IndexByte(p, '\n')
		if newline < 0 {
			s.buffer(p)
			return
		}
		s.buffer(p[:newline])
		if !s.skipped {
			s.handleLine(bytes.TrimRight(s.line, "\r"))
		}
		s.line = s.line[:0]
		s.skipped = false
		p = p[newline+1:]
	}
}

func (s *usageScanner) buffer(p []byte) {
	if s.skipped {
		return
	}
	if len(s.line)+len(p) > maxLine {
		s.skipped = true
		s.line = s.line[:0]
		return
	}
	s.line = append(s.line, p...)
}

type wireUsage struct {
	InputTokens              *int64 `json:"input_tokens"`
	OutputTokens             *int64 `json:"output_tokens"`
	CacheReadInputTokens     *int64 `json:"cache_read_input_tokens"`
	CacheCreationInputTokens *int64 `json:"cache_creation_input_tokens"`
	CacheCreation            *struct {
		Ephemeral5m *int64 `json:"ephemeral_5m_input_tokens"`
		Ephemeral1h *int64 `json:"ephemeral_1h_input_tokens"`
	} `json:"cache_creation"`
}

// merge takes the larger of each count: message_delta counts are
// cumulative, and a field it leaves out keeps message_start's value.
func (s *usageScanner) merge(w *wireUsage) {
	if w == nil {
		return
	}
	s.sawAny = true
	maxInto := func(target *int64, value *int64) {
		if value != nil && *value > *target {
			*target = *value
		}
	}
	maxInto(&s.usage.InputTokens, w.InputTokens)
	maxInto(&s.usage.OutputTokens, w.OutputTokens)
	maxInto(&s.usage.CacheReadTokens, w.CacheReadInputTokens)
	if w.CacheCreation != nil && (w.CacheCreation.Ephemeral5m != nil || w.CacheCreation.Ephemeral1h != nil) {
		maxInto(&s.usage.CacheWrite5mTokens, w.CacheCreation.Ephemeral5m)
		maxInto(&s.usage.CacheWrite1hTokens, w.CacheCreation.Ephemeral1h)
	} else {
		maxInto(&s.usage.CacheWrite5mTokens, w.CacheCreationInputTokens)
	}
}

func (s *usageScanner) handleLine(line []byte) {
	switch {
	case bytes.HasPrefix(line, []byte("event:")):
		s.event = string(bytes.TrimSpace(line[len("event:"):]))
	case bytes.HasPrefix(line, []byte("data:")):
		data := bytes.TrimSpace(line[len("data:"):])
		switch {
		case s.event == "message_start" || bytes.HasPrefix(data, []byte(`{"type":"message_start"`)):
			var payload struct {
				Message struct {
					Model string     `json:"model"`
					Usage *wireUsage `json:"usage"`
				} `json:"message"`
			}
			if json.Unmarshal(data, &payload) == nil {
				if payload.Message.Model != "" {
					s.model = payload.Message.Model
				}
				s.merge(payload.Message.Usage)
			}
		case s.event == "message_delta" || bytes.HasPrefix(data, []byte(`{"type":"message_delta"`)):
			var payload struct {
				Usage *wireUsage `json:"usage"`
			}
			if json.Unmarshal(data, &payload) == nil {
				s.merge(payload.Usage)
			}
		}
	case len(line) == 0:
		s.event = ""
	}
}

// Result is the request's usage, priced, once the reply has ended. The
// model named in the request stands in when the reply didn't say.
func (s *usageScanner) Result(requestModel string) (string, Usage, bool) {
	if !s.stream && !s.skipped && len(s.body) > 0 {
		var payload struct {
			Model string     `json:"model"`
			Usage *wireUsage `json:"usage"`
		}
		if json.Unmarshal(s.body, &payload) == nil {
			if payload.Model != "" {
				s.model = payload.Model
			}
			s.merge(payload.Usage)
		}
		s.body = nil
	}
	if !s.sawAny {
		return "", Usage{}, false
	}
	model := s.model
	if model == "" {
		model = requestModel
	}
	usage := s.usage
	usage.Requests = 1
	usage.CostMicros = costMicros(model, usage)
	return model, usage, true
}
