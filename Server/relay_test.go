package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const goodKey = "sk-ant-api03-good-key-0123456789abcdefghijklmnopqrstuvwxyz"
const otherKey = "sk-ant-api03-other-key-0123456789abcdefghijklmnopqrstuvwx"
const hostedKey = "sk-ant-api03-hosted-key-0123456789abcdefghijklmnopqrstuv"

// fakeAnthropic accepts goodKey and otherKey; /v1/messages streams three
// SSE events and holds the last one until release is closed.
type fakeAnthropic struct {
	server   *httptest.Server
	release  chan struct{}
	once     sync.Once
	lastKey  atomic.Value
	lastBody atomic.Value
	calls    atomic.Int32
}

func newFakeAnthropic(t *testing.T) *fakeAnthropic {
	f := &fakeAnthropic{release: make(chan struct{})}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls.Add(1)
		key := r.Header.Get("X-Api-Key")
		f.lastKey.Store(key)
		if key != goodKey && key != otherKey && key != hostedKey {
			w.WriteHeader(http.StatusUnauthorized)
			io.WriteString(w, `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`)
			return
		}
		if r.Header.Get("Anthropic-Version") == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		switch r.URL.Path {
		case "/v1/models":
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"data":[{"id":"claude-haiku-5-5"}]}`)
		case "/v1/messages":
			body, err := io.ReadAll(r.Body)
			if err != nil {
				return
			}
			f.lastBody.Store(string(body))
			w.Header().Set("Content-Type", "text/event-stream")
			w.Header().Set("Request-Id", "req_test")
			w.Header().Set("Anthropic-Ratelimit-Requests-Remaining", "99")
			flusher := w.(http.Flusher)
			io.WriteString(w, "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-haiku-5-5\",\"content\":[],\"usage\":{\"input_tokens\":1000,\"cache_read_input_tokens\":20000,\"cache_creation_input_tokens\":500,\"output_tokens\":1}}}\n\n")
			flusher.Flush()
			io.WriteString(w, "event: content_block_delta\ndata: {\"delta\":{\"text\":\"Hi\"}}\n\n")
			flusher.Flush()
			<-f.release
			io.WriteString(w, "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":200}}\n\n")
			io.WriteString(w, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.server.Close)
	t.Cleanup(f.releaseAll) // runs first: lets held streams finish
	return f
}

func (f *fakeAnthropic) releaseAll() { f.once.Do(func() { close(f.release) }) }

type harness struct {
	relay    *httptest.Server
	server   *Server
	upstream *fakeAnthropic
	dataDir  string
	clock    time.Time
}

func newHarness(t *testing.T, mutate ...func(*Server)) *harness {
	t.Helper()
	h := &harness{upstream: newFakeAnthropic(t), dataDir: t.TempDir(), clock: time.Date(2026, 10, 11, 9, 0, 0, 0, time.UTC)}
	master, err := LoadOrCreateMasterKey(h.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	keys, err := DeriveKeys(master)
	if err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(h.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	upstream, _ := url.Parse(h.upstream.server.URL)
	meter, err := OpenMeter(h.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	h.server = &Server{
		store: store, keys: keys, upstream: upstream, client: NewUpstreamClient(),
		maxBody: 1 << 20, perAccount: NewLimiter(600, 100), perAddress: NewLimiter(60, 20),
		log: slog.New(slog.NewTextHandler(io.Discard, nil)), version: "test",
		now: func() time.Time { return h.clock }, meter: meter, dataDir: h.dataDir,
	}
	for _, m := range mutate {
		m(h.server)
	}
	h.relay = httptest.NewServer(h.server.Routes())
	t.Cleanup(h.relay.Close)
	return h
}

func (h *harness) do(t *testing.T, method, path, token string, body any) *http.Response {
	t.Helper()
	var reader io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		reader = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, h.relay.URL+path, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Anthropic-Version", "2023-06-01")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func (h *harness) register(t *testing.T, key string) string {
	t.Helper()
	resp := h.do(t, http.MethodPost, "/v1/register", "", map[string]string{"api_key": key, "label": "Test Mac"})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("register: %d %s", resp.StatusCode, raw)
	}
	var out struct {
		Token string `json:"token"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	if !strings.HasPrefix(out.Token, "saaa_") {
		t.Fatalf("token %q", out.Token)
	}
	return out.Token
}

func errorType(t *testing.T, resp *http.Response) string {
	t.Helper()
	defer resp.Body.Close()
	var out struct {
		Error struct {
			Type string `json:"type"`
		} `json:"error"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	return out.Error.Type
}

func TestRegisterVerifiesTheKeyWithAnthropic(t *testing.T) {
	h := newHarness(t)
	resp := h.do(t, http.MethodPost, "/v1/register", "", map[string]string{"api_key": "sk-ant-api03-wrong-0123456789abcdefghijklmnopqrstuvwxyz"})
	if resp.StatusCode != http.StatusUnauthorized || errorType(t, resp) != "authentication_error" {
		t.Fatalf("bad key: %d", resp.StatusCode)
	}
	resp = h.do(t, http.MethodPost, "/v1/register", "", map[string]string{"api_key": "not-a-key"})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("malformed key: %d", resp.StatusCode)
	}
	token := h.register(t, goodKey)
	resp = h.do(t, http.MethodGet, "/v1/account", token, nil)
	defer resp.Body.Close()
	var account accountView
	json.NewDecoder(resp.Body).Decode(&account)
	if account.KeyHint != "sk-ant-…wxyz" || account.Devices != 1 {
		t.Fatalf("account %+v", account)
	}
}

func TestMessagesStreamThroughWithTheSealedKey(t *testing.T) {
	h := newHarness(t)
	token := h.register(t, goodKey)
	resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{"model": "claude-haiku-5-5", "stream": true})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if resp.Header.Get("Request-Id") != "req_test" || resp.Header.Get("Anthropic-Ratelimit-Requests-Remaining") != "99" {
		t.Fatalf("headers not relayed: %v", resp.Header)
	}
	// The first events arrive while Anthropic is still holding the stream open.
	reader := bufio.NewReader(resp.Body)
	var seen []string
	for len(seen) < 2 {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read before release: %v", err)
		}
		if strings.HasPrefix(line, "event: ") {
			seen = append(seen, strings.TrimSpace(strings.TrimPrefix(line, "event: ")))
		}
	}
	if seen[0] != "message_start" || seen[1] != "content_block_delta" {
		t.Fatalf("events %v", seen)
	}
	h.upstream.releaseAll()
	rest, _ := io.ReadAll(reader)
	if !strings.Contains(string(rest), "message_stop") {
		t.Fatalf("missing stop: %q", rest)
	}
	if h.upstream.lastKey.Load() != goodKey {
		t.Fatal("upstream did not get the user's key")
	}
	if body, _ := h.upstream.lastBody.Load().(string); !strings.Contains(body, "claude-haiku-5-5") {
		t.Fatalf("body not relayed: %q", body)
	}
}

func TestUnknownTokensAreRefused(t *testing.T) {
	h := newHarness(t)
	for _, token := range []string{"", "sk-ant-direct", "saaa_made_up"} {
		resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{})
		if resp.StatusCode != http.StatusUnauthorized || errorType(t, resp) != "relay_unauthorized" {
			t.Fatalf("token %q: %d", token, resp.StatusCode)
		}
	}
	if h.upstream.calls.Load() != 0 {
		t.Fatal("refused requests must not reach Anthropic")
	}
}

func TestSecondDeviceWithTheSameKeyJoinsTheAccount(t *testing.T) {
	h := newHarness(t)
	first := h.register(t, goodKey)
	second := h.register(t, goodKey)
	if first == second {
		t.Fatal("each device needs its own token")
	}
	resp := h.do(t, http.MethodGet, "/v1/account", second, nil)
	defer resp.Body.Close()
	var account accountView
	json.NewDecoder(resp.Body).Decode(&account)
	if account.Devices != 2 {
		t.Fatalf("devices %d", account.Devices)
	}
	// Signing one device out leaves the other working.
	if resp := h.do(t, http.MethodDelete, "/v1/token", first, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke %d", resp.StatusCode)
	}
	if resp := h.do(t, http.MethodGet, "/v1/account", first, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("revoked token still works: %d", resp.StatusCode)
	}
	if resp := h.do(t, http.MethodGet, "/v1/account", second, nil); resp.StatusCode != http.StatusOK {
		t.Fatalf("other device signed out: %d", resp.StatusCode)
	}
}

func TestReplaceAndDeleteKey(t *testing.T) {
	h := newHarness(t)
	token := h.register(t, goodKey)
	resp := h.do(t, http.MethodPut, "/v1/account/key", token, map[string]string{"api_key": otherKey})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("replace %d", resp.StatusCode)
	}
	resp.Body.Close()
	h.upstream.releaseAll()
	resp = h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{})
	io.ReadAll(resp.Body)
	resp.Body.Close()
	if h.upstream.lastKey.Load() != otherKey {
		t.Fatal("replaced key not used")
	}
	if resp := h.do(t, http.MethodDelete, "/v1/account", token, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete %d", resp.StatusCode)
	}
	if resp := h.do(t, http.MethodGet, "/v1/account", token, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatal("deleted account still answers")
	}
}

func TestStoreKeepsOnlySealedKeysAndHashedTokens(t *testing.T) {
	h := newHarness(t)
	token := h.register(t, goodKey)
	raw, err := os.ReadFile(filepath.Join(h.dataDir, "accounts.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), goodKey) || strings.Contains(string(raw), token) {
		t.Fatal("plaintext key or token on disk")
	}
	for _, name := range []string{"accounts.json", "master.key"} {
		info, _ := os.Stat(filepath.Join(h.dataDir, name))
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode %v", name, info.Mode().Perm())
		}
	}
	// A restart with the same master key reopens everything.
	store, err := OpenStore(h.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	account, _, ok := store.Authenticate(token, time.Now())
	if !ok {
		t.Fatal("token lost across restart")
	}
	if key, err := h.server.keys.Open(account.SealedKey, account.ID); err != nil || key != goodKey {
		t.Fatalf("reopen: %v", err)
	}
	// Another master key can't read it, and the seal is bound to the account.
	otherMaster := bytes.Repeat([]byte{7}, 32)
	otherKeys, _ := DeriveKeys(otherMaster)
	if _, err := otherKeys.Open(account.SealedKey, account.ID); err == nil {
		t.Fatal("opened with the wrong master key")
	}
	if _, err := h.server.keys.Open(account.SealedKey, "acct_other"); err == nil {
		t.Fatal("seal not bound to its account")
	}
}

func TestRateLimitsAnswerWithRetryAfter(t *testing.T) {
	h := newHarness(t, func(s *Server) { s.perAccount = NewLimiter(60, 2) })
	token := h.register(t, goodKey)
	h.upstream.releaseAll()
	for i := 0; i < 2; i++ {
		resp := h.do(t, http.MethodGet, "/v1/models", token, nil)
		io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("request %d: %d", i, resp.StatusCode)
		}
	}
	resp := h.do(t, http.MethodGet, "/v1/models", token, nil)
	if resp.StatusCode != http.StatusTooManyRequests || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("expected 429 with Retry-After, got %d", resp.StatusCode)
	}
	resp.Body.Close()
	h.clock = h.clock.Add(2 * time.Second)
	resp = h.do(t, http.MethodGet, "/v1/models", token, nil)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("bucket did not refill: %d", resp.StatusCode)
	}
}

func TestOversizedBodiesAreRejected(t *testing.T) {
	h := newHarness(t, func(s *Server) { s.maxBody = 1024 })
	token := h.register(t, goodKey)
	resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]string{"pad": strings.Repeat("x", 4096)})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestRegistrationCodeWhenConfigured(t *testing.T) {
	h := newHarness(t, func(s *Server) { s.registrationCode = "letmein" })
	resp := h.do(t, http.MethodPost, "/v1/register", "", map[string]string{"api_key": goodKey})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("no code: %d", resp.StatusCode)
	}
	resp.Body.Close()
	resp = h.do(t, http.MethodPost, "/v1/register", "", map[string]string{"api_key": goodKey, "registration_code": "letmein"})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("with code: %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestHealthAndInfo(t *testing.T) {
	h := newHarness(t)
	resp, err := http.Get(h.relay.URL + "/healthz")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("health: %v", err)
	}
	resp.Body.Close()
	resp, _ = http.Get(h.relay.URL + "/")
	var info map[string]string
	json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if info["name"] != "saaa-relay" {
		t.Fatalf("info %v", info)
	}
}
