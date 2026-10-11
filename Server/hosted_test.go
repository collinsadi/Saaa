package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func withHosted(budgetMicros int64) func(*Server) {
	return func(s *Server) {
		s.hosted = &HostedConfig{APIKey: hostedKey, BudgetMicros: budgetMicros, Models: []string{"claude-haiku-5-5", "claude-sonnet-5-5"}}
	}
}

func (h *harness) join(t *testing.T, body map[string]string) (string, int) {
	t.Helper()
	resp := h.do(t, http.MethodPost, "/v1/hosted/join", "", body)
	defer resp.Body.Close()
	var out struct {
		Token string `json:"token"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	return out.Token, resp.StatusCode
}

func (h *harness) invite(t *testing.T, budgetMicros int64, uses int) string {
	t.Helper()
	code, err := CreateInvite(h.dataDir, "beta", budgetMicros, uses, 30*24*time.Hour, "test", h.clock)
	if err != nil {
		t.Fatal(err)
	}
	return code
}

func TestHostedJoinNeedsAValidInviteAndUsesItOnce(t *testing.T) {
	h := newHarness(t, withHosted(5_000_000))
	code := h.invite(t, 0, 1)
	if !strings.HasPrefix(code, "SAAA-") || len(code) != len("SAAA-XXXX-XXXX") {
		t.Fatalf("code %q", code)
	}
	token, status := h.join(t, map[string]string{"invite_code": strings.ToLower(code), "label": "Mac"})
	if status != http.StatusOK || !strings.HasPrefix(token, "saaa_") {
		t.Fatalf("join %d %q", status, token)
	}
	if _, status := h.join(t, map[string]string{"invite_code": code}); status != http.StatusForbidden {
		t.Fatalf("second use %d", status)
	}
	if _, status := h.join(t, map[string]string{"invite_code": "SAAA-0000-0000"}); status != http.StatusForbidden {
		t.Fatalf("made-up code %d", status)
	}
	resp := h.do(t, http.MethodGet, "/v1/account", token, nil)
	defer resp.Body.Close()
	var account accountView
	json.NewDecoder(resp.Body).Decode(&account)
	if account.Kind != "hosted" || account.Plan != "beta" || account.KeyHint != "Hosted by Saaa" {
		t.Fatalf("account %+v", account)
	}
	// Only the code's hash is on disk.
	raw, _ := os.ReadFile(filepath.Join(h.dataDir, "invites.json"))
	if strings.Contains(string(raw), code) {
		t.Fatal("plaintext invite code on disk")
	}
	if info, _ := os.Stat(filepath.Join(h.dataDir, "invites.json")); info.Mode().Perm() != 0o600 {
		t.Fatalf("invites mode %v", info.Mode().Perm())
	}
}

func TestHostedRequestsUseTheServerKeyAndAllowedModels(t *testing.T) {
	h := newHarness(t, withHosted(5_000_000))
	token, _ := h.join(t, map[string]string{"invite_code": h.invite(t, 0, 1)})
	h.upstream.releaseAll()
	resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{"model": "claude-haiku-5-5", "stream": true})
	io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || h.upstream.lastKey.Load() != hostedKey {
		t.Fatalf("status %d, key %v", resp.StatusCode, h.upstream.lastKey.Load())
	}
	if body, _ := h.upstream.lastBody.Load().(string); !strings.Contains(body, "claude-haiku-5-5") {
		t.Fatalf("buffered body not forwarded: %q", body)
	}
	calls := h.upstream.calls.Load()
	resp = h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{"model": "claude-opus-5-5"})
	if resp.StatusCode != http.StatusForbidden || errorType(t, resp) != "permission_error" {
		t.Fatalf("opus %d", resp.StatusCode)
	}
	if h.upstream.calls.Load() != calls {
		t.Fatal("a refused model reached Anthropic")
	}
	// Hosted accounts have no key of their own to replace.
	if resp := h.do(t, http.MethodPut, "/v1/account/key", token, map[string]string{"api_key": goodKey}); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("replace key %d", resp.StatusCode)
	}
}

func TestTheMonthlyAllowanceAnswers402(t *testing.T) {
	h := newHarness(t, withHosted(5_000_000))
	// One request costs more than this invite's allowance.
	token, _ := h.join(t, map[string]string{"invite_code": h.invite(t, 100, 1)})
	h.upstream.releaseAll()
	resp := h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{"model": "claude-haiku-5-5"})
	io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("first %d", resp.StatusCode)
	}
	calls := h.upstream.calls.Load()
	resp = h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{"model": "claude-haiku-5-5"})
	if resp.StatusCode != http.StatusPaymentRequired || errorType(t, resp) != "quota_exceeded" {
		t.Fatalf("over the allowance %d", resp.StatusCode)
	}
	if h.upstream.calls.Load() != calls {
		t.Fatal("an over-allowance request reached Anthropic")
	}
	resp = h.do(t, http.MethodGet, "/v1/usage", token, nil)
	defer resp.Body.Close()
	var usage usageView
	json.NewDecoder(resp.Body).Decode(&usage)
	if usage.Kind != "hosted" || usage.BudgetUSD == nil || *usage.BudgetUSD != 0.0001 || usage.RemainingUSD == nil || *usage.RemainingUSD != 0 {
		t.Fatalf("usage %+v", usage)
	}
	// A new month starts fresh.
	h.clock = h.clock.AddDate(0, 1, 0)
	resp = h.do(t, http.MethodPost, "/v1/messages", token, map[string]any{"model": "claude-haiku-5-5"})
	io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("next month %d", resp.StatusCode)
	}
}

func TestLinkCodesAddASecondMacOnce(t *testing.T) {
	h := newHarness(t, withHosted(5_000_000))
	first, _ := h.join(t, map[string]string{"invite_code": h.invite(t, 0, 1)})
	resp := h.do(t, http.MethodPost, "/v1/account/link", first, nil)
	var out struct {
		LinkCode  string `json:"link_code"`
		ExpiresIn int    `json:"expires_in"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	if out.LinkCode == "" || out.ExpiresIn != 600 {
		t.Fatalf("link %+v", out)
	}
	second, status := h.join(t, map[string]string{"link_code": out.LinkCode, "label": "Studio"})
	if status != http.StatusOK || second == first {
		t.Fatalf("join with link %d", status)
	}
	resp = h.do(t, http.MethodGet, "/v1/account", second, nil)
	var account accountView
	json.NewDecoder(resp.Body).Decode(&account)
	resp.Body.Close()
	if account.Devices != 2 {
		t.Fatalf("devices %d", account.Devices)
	}
	if _, status := h.join(t, map[string]string{"link_code": out.LinkCode}); status != http.StatusForbidden {
		t.Fatalf("reused link %d", status)
	}
	// Expired codes don't work.
	resp = h.do(t, http.MethodPost, "/v1/account/link", first, nil)
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	h.clock = h.clock.Add(11 * time.Minute)
	if _, status := h.join(t, map[string]string{"link_code": out.LinkCode}); status != http.StatusForbidden {
		t.Fatalf("expired link %d", status)
	}
	// Bring-your-own-key accounts add Macs with the same key instead.
	byok := h.register(t, goodKey)
	if resp := h.do(t, http.MethodPost, "/v1/account/link", byok, nil); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("byok link %d", resp.StatusCode)
	}
}

func TestHostedJoinIsOffUnlessConfigured(t *testing.T) {
	h := newHarness(t)
	code := h.invite(t, 0, 1)
	if _, status := h.join(t, map[string]string{"invite_code": code}); status != http.StatusNotFound {
		t.Fatalf("join on a byok-only server %d", status)
	}
}

func TestInvitesExpireAndCountUses(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 10, 11, 9, 0, 0, 0, time.UTC)
	code, err := CreateInvite(dir, "beta", 0, 2, time.Hour, "", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := RedeemInvite(dir, code, now.Add(2*time.Hour)); err != ErrInviteInvalid {
		t.Fatalf("expired: %v", err)
	}
	other, _ := CreateInvite(dir, "beta", 0, 2, 0, "", now)
	for i := 0; i < 2; i++ {
		if _, err := RedeemInvite(dir, other, now); err != nil {
			t.Fatalf("use %d: %v", i, err)
		}
	}
	if _, err := RedeemInvite(dir, other, now); err != ErrInviteInvalid {
		t.Fatalf("third use: %v", err)
	}
	// Typed sloppily, a code still works: lower case, O for 0, spaces.
	sloppy, _ := CreateInvite(dir, "beta", 0, 1, 0, "", now)
	typed := strings.ToLower(strings.ReplaceAll(sloppy, "0", "O"))
	if _, err := RedeemInvite(dir, " "+typed+" ", now); err != nil {
		t.Fatalf("sloppy code: %v", err)
	}
}

func TestHostedAccountsSurviveARestartWithoutAKey(t *testing.T) {
	h := newHarness(t, withHosted(5_000_000))
	token, _ := h.join(t, map[string]string{"invite_code": h.invite(t, 0, 1)})
	h.register(t, goodKey)
	store, err := OpenStore(h.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	account, _, ok := store.Authenticate(token, time.Now())
	if !ok || !account.Hosted() || account.SealedKey != "" || account.Fingerprint != "" {
		t.Fatalf("hosted account after restart: %+v", account)
	}
	if len(store.byPrint) != 1 {
		t.Fatalf("fingerprints %d", len(store.byPrint))
	}
}
