package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Server is the Saaa relay: devices hold an access token, the server holds
// each user's Anthropic key sealed, and requests stream through untouched.
// Nothing a request carries (prompts, transcripts, answers, keys, tokens)
// is ever logged or stored.
type Server struct {
	store            *Store
	keys             *Keys
	upstream         *url.URL
	client           *http.Client
	maxBody          int64
	perAccount       *Limiter
	perAddress       *Limiter
	registrationCode string
	trustProxy       bool
	log              *slog.Logger
	version          string
	now              func() time.Time
}

const anthropicVersion = "2023-06-01"

func NewUpstreamClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			ForceAttemptHTTP2:     true,
			MaxIdleConns:          256,
			MaxIdleConnsPerHost:   64,
			IdleConnTimeout:       5 * time.Minute,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: time.Second,
			// Streams must arrive byte for byte as Anthropic sends them.
			DisableCompression: true,
			DialContext: (&net.Dialer{
				Timeout:   10 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
		},
	}
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.info)
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("POST /v1/register", s.register)
	mux.HandleFunc("GET /v1/account", s.account)
	mux.HandleFunc("PUT /v1/account/key", s.replaceKey)
	mux.HandleFunc("DELETE /v1/account", s.deleteAccount)
	mux.HandleFunc("DELETE /v1/token", s.revokeToken)
	mux.HandleFunc("POST /v1/messages", s.proxy)
	mux.HandleFunc("POST /v1/messages/count_tokens", s.proxy)
	mux.HandleFunc("GET /v1/models", s.proxy)
	return s.logged(mux)
}

// MARK: - Basics

func (s *Server) info(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"name": "saaa-relay", "version": s.version})
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	io.WriteString(w, "ok\n")
}

// MARK: - Accounts

type registerRequest struct {
	APIKey           string `json:"api_key"`
	Label            string `json:"label"`
	RegistrationCode string `json:"registration_code"`
}

type accountView struct {
	ID        string    `json:"id"`
	KeyHint   string    `json:"key_hint"`
	Devices   int       `json:"devices"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func (s *Server) view(a *Account) accountView {
	return accountView{ID: a.ID, KeyHint: a.KeyHint, Devices: s.store.Devices(a.ID), CreatedAt: a.CreatedAt, UpdatedAt: a.UpdatedAt}
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	now := s.now()
	if ok, wait := s.perAddress.Allow("register:"+s.clientAddress(r), now); !ok {
		rateLimited(w, wait)
		return
	}
	var body registerRequest
	if !decodeJSON(w, r, &body) {
		return
	}
	if s.registrationCode != "" &&
		subtle.ConstantTimeCompare([]byte(body.RegistrationCode), []byte(s.registrationCode)) != 1 {
		writeError(w, http.StatusForbidden, "permission_error", "This Saaa server needs an invitation code.")
		return
	}
	key := strings.TrimSpace(body.APIKey)
	if !LooksLikeAnthropicKey(key) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "That doesn't look like a Claude API key. Keys start with sk-ant-.")
		return
	}
	latency, ok := s.verifyKey(r.Context(), w, key)
	if !ok {
		return
	}
	account, token, joined, err := s.store.Register(s.keys, key, cleanLabel(body.Label), now)
	if err != nil {
		s.log.Error("register failed", "error", err.Error())
		writeError(w, http.StatusInternalServerError, "api_error", "The server couldn't save the key. Try again.")
		return
	}
	s.log.Info("device connected", "account", short(account.ID), "joined_existing", joined)
	writeJSON(w, http.StatusOK, map[string]any{
		"token":           token,
		"account":         s.view(account),
		"joined_existing": joined,
		"verified_ms":     latency.Milliseconds(),
	})
}

func (s *Server) account(w http.ResponseWriter, r *http.Request) {
	account, _, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, s.view(account))
}

func (s *Server) replaceKey(w http.ResponseWriter, r *http.Request) {
	account, _, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	var body registerRequest
	if !decodeJSON(w, r, &body) {
		return
	}
	key := strings.TrimSpace(body.APIKey)
	if !LooksLikeAnthropicKey(key) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "That doesn't look like a Claude API key. Keys start with sk-ant-.")
		return
	}
	if _, ok := s.verifyKey(r.Context(), w, key); !ok {
		return
	}
	updated, err := s.store.ReplaceKey(s.keys, account.ID, key, s.now())
	switch {
	case errors.Is(err, ErrKeyInUse):
		writeError(w, http.StatusConflict, "invalid_request_error", "That key is already connected under another account. Connect with it instead.")
	case err != nil:
		writeError(w, http.StatusInternalServerError, "api_error", "The server couldn't save the key. Try again.")
	default:
		writeJSON(w, http.StatusOK, s.view(updated))
	}
}

func (s *Server) deleteAccount(w http.ResponseWriter, r *http.Request) {
	account, _, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if err := s.store.DeleteAccount(account.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "api_error", "The server couldn't delete the account. Try again.")
		return
	}
	s.log.Info("account deleted", "account", short(account.ID))
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) revokeToken(w http.ResponseWriter, r *http.Request) {
	_, token, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if err := s.store.RevokeToken(token); err != nil {
		writeError(w, http.StatusInternalServerError, "api_error", "The server couldn't sign this device out. Try again.")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// verifyKey asks Anthropic whether the key works, using the free models
// listing. Writes the error response itself when it doesn't.
func (s *Server) verifyKey(ctx context.Context, w http.ResponseWriter, key string) (time.Duration, bool) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	target := *s.upstream
	target.Path = "/v1/models"
	target.RawQuery = "limit=1"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "api_error", "The key check failed to start.")
		return 0, false
	}
	req.Header.Set("X-Api-Key", key)
	req.Header.Set("Anthropic-Version", anthropicVersion)
	started := time.Now()
	resp, err := s.client.Do(req)
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "Couldn't reach Anthropic to check the key. Try again.")
		return 0, false
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusOK:
		return time.Since(started), true
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		writeError(w, http.StatusUnauthorized, "authentication_error", "Anthropic didn't accept that key. Check that you copied all of it.")
	case resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500:
		writeError(w, http.StatusBadGateway, "api_error", "Anthropic is busy right now. Try again in a moment.")
	default:
		writeError(w, http.StatusBadGateway, "api_error", fmt.Sprintf("Anthropic answered the key check with status %d.", resp.StatusCode))
	}
	return 0, false
}

// MARK: - Relay

var responseHeaders = []string{"Content-Type", "Request-Id", "Retry-After", "X-Should-Retry"}

var bufferPool = sync.Pool{New: func() any { b := make([]byte, 32*1024); return &b }}

func (s *Server) proxy(w http.ResponseWriter, r *http.Request) {
	account, _, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if ok, wait := s.perAccount.Allow(account.ID, s.now()); !ok {
		rateLimited(w, wait)
		return
	}
	apiKey, err := s.keys.Open(account.SealedKey, account.ID)
	if err != nil {
		s.log.Error("sealed key unreadable", "account", short(account.ID))
		writeError(w, http.StatusInternalServerError, "api_error", "The server couldn't unlock your key. Connect again in Settings.")
		return
	}

	target := *s.upstream
	target.Path = r.URL.Path
	target.RawQuery = r.URL.RawQuery
	var body io.Reader = http.NoBody
	if r.Method == http.MethodPost {
		body = http.MaxBytesReader(w, r.Body, s.maxBody)
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, target.String(), body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "Bad request.")
		return
	}
	if r.Method == http.MethodPost && r.ContentLength >= 0 {
		req.ContentLength = r.ContentLength
	}
	for _, name := range []string{"Content-Type", "Accept", "Anthropic-Version", "Anthropic-Beta"} {
		if values := r.Header.Values(name); len(values) > 0 {
			req.Header[name] = values
		}
	}
	if req.Header.Get("Anthropic-Version") == "" {
		req.Header.Set("Anthropic-Version", anthropicVersion)
	}
	req.Header.Set("X-Api-Key", apiKey)

	resp, err := s.client.Do(req)
	if err != nil {
		if r.Context().Err() != nil {
			return // the device went away; nothing to answer
		}
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "The request is too large for this server.")
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "Couldn't reach Anthropic. Check the server's connection.")
		return
	}
	defer resp.Body.Close()

	for _, name := range responseHeaders {
		if values := resp.Header.Values(name); len(values) > 0 {
			w.Header()[name] = values
		}
	}
	for name, values := range resp.Header {
		if strings.HasPrefix(strings.ToLower(name), "anthropic-") {
			w.Header()[name] = values
		}
	}
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Accel-Buffering", "no")
	}
	w.WriteHeader(resp.StatusCode)

	// Every chunk goes out the moment it arrives: first-token time is the product.
	controller := http.NewResponseController(w)
	bufPtr := bufferPool.Get().(*[]byte)
	defer bufferPool.Put(bufPtr)
	buf := *bufPtr
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, err := w.Write(buf[:n]); err != nil {
				return
			}
			if err := controller.Flush(); err != nil {
				return
			}
		}
		if readErr != nil {
			return
		}
	}
}

// MARK: - Helpers

const unauthorizedMessage = "This device isn't connected to your Saaa server. Connect again in Settings."

func bearerToken(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if len(header) > 7 && strings.EqualFold(header[:7], "Bearer ") {
		return strings.TrimSpace(header[7:])
	}
	return ""
}

func (s *Server) authenticate(w http.ResponseWriter, r *http.Request) (*Account, string, bool) {
	token := bearerToken(r)
	if !strings.HasPrefix(token, "saaa_") {
		writeError(w, http.StatusUnauthorized, "relay_unauthorized", unauthorizedMessage)
		return nil, "", false
	}
	account, _, ok := s.store.Authenticate(token, s.now())
	if !ok {
		writeError(w, http.StatusUnauthorized, "relay_unauthorized", unauthorizedMessage)
		return nil, "", false
	}
	setAccount(r, account.ID)
	return account, token, true
}

func (s *Server) clientAddress(r *http.Request) string {
	if s.trustProxy {
		if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
			return strings.TrimSpace(strings.Split(forwarded, ",")[0])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func decodeJSON(w http.ResponseWriter, r *http.Request, into any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024))
	if err := decoder.Decode(into); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "The request body isn't valid JSON.")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(value)
}

// writeError answers in Anthropic's error shape so clients handle both alike.
func writeError(w http.ResponseWriter, status int, kind, message string) {
	writeJSON(w, status, map[string]any{
		"type":  "error",
		"error": map[string]string{"type": kind, "message": message},
	})
}

func rateLimited(w http.ResponseWriter, wait time.Duration) {
	seconds := int(wait.Seconds()) + 1
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	writeError(w, http.StatusTooManyRequests, "rate_limit_error", "Too many requests to your Saaa server. Slow down for a moment.")
}

func cleanLabel(label string) string {
	label = strings.TrimSpace(label)
	label = strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, label)
	if len([]rune(label)) > 64 {
		label = string([]rune(label)[:64])
	}
	return label
}

func short(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}

// MARK: - Request log (metadata only)

type accountKey struct{}

type requestInfo struct{ account string }

func setAccount(r *http.Request, id string) {
	if info, ok := r.Context().Value(accountKey{}).(*requestInfo); ok {
		info.account = short(id)
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (s *statusRecorder) WriteHeader(status int) {
	if s.status == 0 {
		s.status = status
	}
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	n, err := s.ResponseWriter.Write(b)
	s.bytes += int64(n)
	return n, err
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func (s *Server) logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		info := &requestInfo{}
		r = r.WithContext(context.WithValue(r.Context(), accountKey{}, info))
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)
		if r.URL.Path == "/healthz" {
			return
		}
		s.log.Info("request",
			"method", r.Method, "path", r.URL.Path, "status", recorder.status,
			"ms", time.Since(started).Milliseconds(), "bytes", recorder.bytes, "account", info.account)
	})
}
