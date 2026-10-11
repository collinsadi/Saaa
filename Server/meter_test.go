package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

const sampleStream = "event: message_start\n" +
	`data: {"type":"message_start","message":{"id":"msg_1","model":"claude-haiku-5-5","content":[],"usage":{"input_tokens":1200,"cache_read_input_tokens":3000,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_5m_input_tokens":200,"ephemeral_1h_input_tokens":300},"output_tokens":1}}}` + "\n\n" +
	"event: content_block_delta\n" +
	`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The usage field says 9999 output_tokens"}}` + "\n\n" +
	"event: message_delta\n" +
	`data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}` + "\n\n" +
	"event: message_stop\n" +
	`data: {"type":"message_stop"}` + "\n\n"

func TestScannerReadsUsageHoweverTheStreamIsSplit(t *testing.T) {
	for _, size := range []int{1, 2, 7, 64, len(sampleStream)} {
		scanner := newUsageScanner("text/event-stream; charset=utf-8")
		for start := 0; start < len(sampleStream); start += size {
			end := min(start+size, len(sampleStream))
			scanner.Write([]byte(sampleStream[start:end]))
		}
		model, usage, complete := scanner.Result("")
		if !complete || !scanner.seen() || model != "claude-haiku-5-5" {
			t.Fatalf("chunk %d: complete %v model %q", size, complete, model)
		}
		want := Usage{InputTokens: 1200, OutputTokens: 42, CacheReadTokens: 3000, CacheWrite5mTokens: 200, CacheWrite1hTokens: 300}
		if usage != want {
			t.Fatalf("chunk %d: %+v, want %+v", size, usage, want)
		}
	}
}

func TestScannerReadsJSONRepliesAndSkipsHugeLines(t *testing.T) {
	scanner := newUsageScanner("application/json")
	scanner.Write([]byte(`{"model":"claude-sonnet-5-5","content":[{"type":"text","text":"x"}],`))
	scanner.Write([]byte(`"usage":{"input_tokens":10,"output_tokens":5}}`))
	model, usage, complete := scanner.Result("")
	if !complete || model != "claude-sonnet-5-5" || usage.InputTokens != 10 || usage.OutputTokens != 5 || costMicros(model, usage) != 70 {
		t.Fatalf("json: %v %q %+v", complete, model, usage)
	}

	stream := newUsageScanner("text/event-stream")
	huge := "event: content_block_delta\ndata: {\"delta\":{\"text\":\"" + strings.Repeat("a", maxLine*2) + "\"}}\n\n"
	stream.Write([]byte(huge))
	stream.Write([]byte(sampleStream))
	if _, usage, complete := stream.Result(""); !complete || usage.OutputTokens != 42 {
		t.Fatalf("after a huge line: %v %+v", complete, usage)
	}
	empty := newUsageScanner("text/event-stream")
	if _, _, complete := empty.Result(""); complete || empty.seen() {
		t.Fatal("a reply with no usage is neither complete nor seen")
	}
}

func TestCostsMatchTheAppsPrices(t *testing.T) {
	if got := costMicros("claude-haiku-5-5", Usage{InputTokens: 1000, OutputTokens: 100}); got != 150 {
		t.Fatalf("haiku %d", got)
	}
	// Past 100K prompt tokens Haiku 5.5 bills every category at 5x.
	if got := costMicros("claude-haiku-5-5", Usage{InputTokens: 150_000}); got != 75_000 {
		t.Fatalf("long context %d", got)
	}
	if got, want := costMicros("claude-unknown", Usage{InputTokens: 1000}), costMicros("claude-sonnet-5-5", Usage{InputTokens: 1000}); got != want {
		t.Fatalf("unknown models price as Sonnet: %d vs %d", got, want)
	}
}

func TestMeterKeepsMonthsAndSurvivesRestarts(t *testing.T) {
	dir := t.TempDir()
	meter, err := OpenMeter(dir)
	if err != nil {
		t.Fatal(err)
	}
	october := time.Date(2026, 10, 31, 23, 0, 0, 0, time.UTC)
	meter.Record("acct_a", october, Usage{Requests: 1, CostMicros: 500})
	meter.Record("acct_a", october, Usage{Requests: 1, CostMicros: 250})
	meter.Record("acct_a", october.Add(2*time.Hour), Usage{Requests: 1, CostMicros: 100})
	if err := meter.FlushIfDirty(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenMeter(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := reopened.Month("acct_a", october); got.Requests != 2 || got.CostMicros != 750 {
		t.Fatalf("october %+v", got)
	}
	if got := reopened.Month("acct_a", october.Add(2*time.Hour)); got.CostMicros != 100 {
		t.Fatalf("november %+v", got)
	}
	if !periodEnd(october).Equal(time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatal("period end")
	}
}

func TestProxyMetersStreamsWithoutHoldingThemBack(t *testing.T) {
	h := newHarness(t)
	token := h.register(t, goodKey)
	h.upstream.releaseAll()
	resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{"model": "claude-haiku-5-5", "stream": true})
	io.ReadAll(resp.Body)
	resp.Body.Close()

	resp = h.do(t, http.MethodGet, "/v1/usage", token, nil)
	defer resp.Body.Close()
	var usage usageView
	json.NewDecoder(resp.Body).Decode(&usage)
	if usage.Kind != "byok" || usage.Requests != 1 || usage.InputTokens != 1000 || usage.OutputTokens != 200 ||
		usage.CacheReadTokens != 20000 || usage.CacheWriteTokens != 500 || usage.BudgetUSD != nil {
		t.Fatalf("usage %+v", usage)
	}
	want := dollars(costMicros("claude-haiku-5-5", Usage{InputTokens: 1000, OutputTokens: 200, CacheReadTokens: 20000, CacheWrite5mTokens: 500}))
	if usage.CostUSD != want || usage.Period != "2026-10" {
		t.Fatalf("cost %v want %v, period %s", usage.CostUSD, want, usage.Period)
	}
	// Failed and non-message requests aren't metered.
	resp = h.do(t, http.MethodGet, "/v1/models", token, nil)
	io.ReadAll(resp.Body)
	resp.Body.Close()
	if got := h.server.meter.Month(firstAccount(t, h), h.clock); got.Requests != 1 {
		t.Fatalf("requests %d", got.Requests)
	}
}

func firstAccount(t *testing.T, h *harness) string {
	t.Helper()
	h.server.store.mu.RLock()
	defer h.server.store.mu.RUnlock()
	for id := range h.server.store.accounts {
		return id
	}
	t.Fatal("no account")
	return ""
}
