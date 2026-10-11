package main

import (
	"bufio"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// hostedWithUpstream is a hosted harness whose Anthropic is `upstream`.
func hostedWithUpstream(t *testing.T, upstream http.Handler, budgetMicros int64) (*harness, string) {
	t.Helper()
	h := newHarness(t, withHosted(5_000_000))
	if upstream != nil {
		fake := httptest.NewServer(upstream)
		t.Cleanup(fake.Close)
		target, _ := url.Parse(fake.URL)
		h.server.upstream = target
	}
	token, status := h.join(t, map[string]string{"invite_code": h.invite(t, budgetMicros, 1)})
	if status != http.StatusOK {
		t.Fatalf("join %d", status)
	}
	return h, token
}

func waitForMeter(t *testing.T, h *harness, account string, requests int64) Usage {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if got := h.server.meter.Month(account, h.clock); got.Requests >= requests {
			return got
		}
		time.Sleep(10 * time.Millisecond)
	}
	return h.server.meter.Month(account, h.clock)
}

func TestAHostedReplyCutShortCountsAtFullLength(t *testing.T) {
	hold := make(chan struct{})
	t.Cleanup(func() { close(hold) })
	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-sonnet-5-5\",\"content\":[],\"usage\":{\"input_tokens\":20,\"output_tokens\":1}}}\n\n")
		for i := 0; i < 50; i++ {
			io.WriteString(w, "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"useful output \"}}\n\n")
		}
		io.WriteString(w, "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n")
		w.(http.Flusher).Flush()
		select { // the final usage would come a moment later
		case <-hold:
		case <-r.Context().Done():
		}
	})
	h, token := hostedWithUpstream(t, upstream, 0)
	resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{"model": "claude-sonnet-5-5", "stream": true, "max_tokens": 5000})
	reader := bufio.NewReader(resp.Body)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if strings.HasPrefix(line, "event: content_block_stop") {
			break
		}
	}
	resp.Body.Close() // the device took the text and hung up before the final count
	got := waitForMeter(t, h, firstAccount(t, h), 1)
	if got.OutputTokens != 5000 || got.InputTokens != 20 {
		t.Fatalf("metered %+v, want the full 5000 output tokens", got)
	}
}

func TestSideBySideRequestsCantOverrunTheAllowance(t *testing.T) {
	// One request costs about 463 micro-dollars; the allowance is 500. The
	// prompt is about the size the fake reports using (21,500 tokens).
	h, token := hostedWithUpstream(t, nil, 500)
	prompt := strings.Repeat("word ", 17_000)
	var wg sync.WaitGroup
	statuses := make([]int, 10)
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{
				"model": "claude-haiku-5-5", "stream": true, "max_tokens": 300,
				"messages": []map[string]any{{"role": "user", "content": prompt}},
			})
			statuses[i] = resp.StatusCode
			io.ReadAll(resp.Body)
			resp.Body.Close()
		}(i)
	}
	time.Sleep(200 * time.Millisecond)
	h.upstream.releaseAll()
	wg.Wait()
	ok := 0
	for _, status := range statuses {
		switch status {
		case http.StatusOK:
			ok++
		case http.StatusTooManyRequests, http.StatusPaymentRequired:
		default:
			t.Fatalf("unexpected status %d", status)
		}
	}
	got := h.server.meter.Month(firstAccount(t, h), h.clock)
	if ok != 1 || got.CostMicros > 500 {
		t.Fatalf("%d requests ran, %d micro-dollars spent of 500: %v", ok, got.CostMicros, statuses)
	}
	h.server.meter.mu.Lock()
	held := len(h.server.meter.reserved)
	h.server.meter.mu.Unlock()
	if held != 0 {
		t.Fatal("reservations outlived their requests")
	}
}

func TestOneHourCacheWritesCountOnce(t *testing.T) {
	stream := "event: message_start\n" +
		`data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","content":[],"usage":{"input_tokens":10,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":300},"output_tokens":1}}}` + "\n\n" +
		"event: message_delta\n" +
		`data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":10,"cache_creation_input_tokens":300,"output_tokens":50}}` + "\n\n"
	scanner := newUsageScanner("text/event-stream")
	scanner.Write([]byte(stream))
	_, usage, complete := scanner.Result("")
	if !complete || usage.CacheWrite5mTokens != 0 || usage.CacheWrite1hTokens != 300 || usage.OutputTokens != 50 {
		t.Fatalf("usage %+v", usage)
	}
	// Without a breakdown, the flat total is a 5-minute write.
	flat := newUsageScanner("application/json")
	flat.Write([]byte(`{"model":"claude-sonnet-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":40,"output_tokens":2}}`))
	if _, usage, _ := flat.Result(""); usage.CacheWrite5mTokens != 40 || usage.CacheWrite1hTokens != 0 {
		t.Fatalf("flat %+v", usage)
	}
}

func TestHostedAccountsCantUseBetasOrServerTools(t *testing.T) {
	h, token := hostedWithUpstream(t, nil, 0)
	h.upstream.releaseAll()
	calls := h.upstream.calls.Load()
	resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{
		"model": "claude-haiku-5-5", "max_tokens": 100,
		"tools": []map[string]any{{"type": "web_search_20250305", "name": "web_search"}},
	})
	if resp.StatusCode != http.StatusForbidden || errorType(t, resp) != "permission_error" {
		t.Fatalf("server tool %d", resp.StatusCode)
	}
	req, _ := http.NewRequest(http.MethodPost, h.relay.URL+"/v1/messages", strings.NewReader(`{"model":"claude-haiku-5-5","max_tokens":10}`))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Anthropic-Beta", "some-beta-2026-01-01")
	beta, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if beta.StatusCode != http.StatusForbidden || errorType(t, beta) != "permission_error" {
		t.Fatalf("beta %d", beta.StatusCode)
	}
	if h.upstream.calls.Load() != calls {
		t.Fatal("a refused request reached Anthropic")
	}
	// Client tools of the app's own are fine.
	resp = h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{
		"model": "claude-haiku-5-5", "max_tokens": 100,
		"tools": []map[string]any{{"name": "record", "input_schema": map[string]any{"type": "object"}}},
	})
	io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("client tool %d", resp.StatusCode)
	}
}
