package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// HostedConfig turns on hosted accounts: people with an invite code use
// the server's own Anthropic key within a monthly allowance, instead of
// bringing a key. Nil means the server is bring-your-own-key only.
type HostedConfig struct {
	// The operator's Anthropic key. Never logged, never sent to devices.
	APIKey string
	// Monthly allowance per hosted account when its invite didn't set one.
	BudgetMicros int64
	// Models hosted accounts may use; requests for others are refused.
	Models []string
}

// MARK: - Invites

// Invite lets someone open a hosted account. Only the code's SHA-256 hash
// is stored, in data/invites.json (mode 0600).
type Invite struct {
	Hash         string     `json:"hash"`
	Plan         string     `json:"plan"`
	BudgetMicros int64      `json:"budget_micros,omitempty"`
	MaxUses      int        `json:"max_uses"`
	Uses         int        `json:"uses"`
	Note         string     `json:"note,omitempty"`
	CreatedAt    time.Time  `json:"created_at"`
	ExpiresAt    *time.Time `json:"expires_at,omitempty"`
}

type inviteFile struct {
	Version int       `json:"version"`
	Invites []*Invite `json:"invites"`
}

var (
	ErrInviteInvalid = errors.New("invite code not valid")
	invitesMu        sync.Mutex
)

// Crockford's base32 without I, L, O and U: easy to read out and type.
const codeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// newCode returns "SAAA-XXXX-XXXX" (40 random bits) or, for link codes,
// "XXXX-XXXX".
func newCode(prefix string) (string, error) {
	raw := make([]byte, 8)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	var b strings.Builder
	if prefix != "" {
		b.WriteString(prefix + "-")
	}
	for i := 0; i < 8; i++ {
		if i == 4 {
			b.WriteByte('-')
		}
		b.WriteByte(codeAlphabet[int(raw[i])%len(codeAlphabet)])
	}
	return b.String(), nil
}

// normalizeCode accepts lower case, spaces and the look-alike letters.
func normalizeCode(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	code = strings.NewReplacer(" ", "", "O", "0", "I", "1", "L", "1").Replace(code)
	return code
}

func hashCode(code string) string {
	sum := sha256.Sum256([]byte(normalizeCode(code)))
	return hex.EncodeToString(sum[:])
}

func invitesPath(dataDir string) string { return filepath.Join(dataDir, "invites.json") }

// lockInvites holds an exclusive file lock on invites.json's neighbor, so
// `saaa-relay invite` and the running server never interleave their read
// and write of the file. The returned function lets go.
func lockInvites(dataDir string) (func(), error) {
	file, err := os.OpenFile(filepath.Join(dataDir, "invites.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		file.Close()
		return nil, err
	}
	return func() {
		syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		file.Close()
	}, nil
}

func loadInvites(dataDir string) (*inviteFile, error) {
	raw, err := os.ReadFile(invitesPath(dataDir))
	if errors.Is(err, os.ErrNotExist) {
		return &inviteFile{Version: 1}, nil
	}
	if err != nil {
		return nil, err
	}
	var file inviteFile
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, err
	}
	if file.Version != 1 {
		return nil, errStoreVersion
	}
	return &file, nil
}

func saveInvites(dataDir string, file *inviteFile) error {
	raw, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(invitesPath(dataDir), raw, 0o600)
}

// CreateInvite adds an invite and returns its code, the only time the
// code exists in plain text.
func CreateInvite(dataDir, plan string, budgetMicros int64, maxUses int, ttl time.Duration, note string, now time.Time) (string, error) {
	invitesMu.Lock()
	defer invitesMu.Unlock()
	unlock, err := lockInvites(dataDir)
	if err != nil {
		return "", err
	}
	defer unlock()
	file, err := loadInvites(dataDir)
	if err != nil {
		return "", err
	}
	code, err := newCode("SAAA")
	if err != nil {
		return "", err
	}
	invite := &Invite{Hash: hashCode(code), Plan: plan, BudgetMicros: budgetMicros, MaxUses: max(1, maxUses), Note: note, CreatedAt: now}
	if ttl > 0 {
		expires := now.Add(ttl)
		invite.ExpiresAt = &expires
	}
	file.Invites = append(file.Invites, invite)
	return code, saveInvites(dataDir, file)
}

// RedeemInvite spends one use of a code. The file is read fresh each time,
// so codes the command line adds work without a restart.
func RedeemInvite(dataDir, code string, now time.Time) (Invite, error) {
	invitesMu.Lock()
	defer invitesMu.Unlock()
	unlock, err := lockInvites(dataDir)
	if err != nil {
		return Invite{}, err
	}
	defer unlock()
	file, err := loadInvites(dataDir)
	if err != nil {
		return Invite{}, err
	}
	hash := hashCode(code)
	for _, invite := range file.Invites {
		if !SameHash(invite.Hash, hash) {
			continue
		}
		if invite.Uses >= invite.MaxUses || (invite.ExpiresAt != nil && now.After(*invite.ExpiresAt)) {
			return Invite{}, ErrInviteInvalid
		}
		invite.Uses++
		if err := saveInvites(dataDir, file); err != nil {
			return Invite{}, err
		}
		return *invite, nil
	}
	return Invite{}, ErrInviteInvalid
}

// MARK: - Link codes

// linkCodes let a second Mac join a hosted account: the first asks for a
// code, the second enters it within ten minutes. Memory only.
type linkCodes struct {
	mu    sync.Mutex
	codes map[string]linkCode // by hash
}

type linkCode struct {
	accountID string
	expires   time.Time
}

const linkCodeLifetime = 10 * time.Minute

func (l *linkCodes) create(accountID string, now time.Time) (string, error) {
	code, err := newCode("")
	if err != nil {
		return "", err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.codes == nil {
		l.codes = map[string]linkCode{}
	}
	for hash, entry := range l.codes {
		if now.After(entry.expires) {
			delete(l.codes, hash)
		}
	}
	l.codes[hashCode(code)] = linkCode{accountID: accountID, expires: now.Add(linkCodeLifetime)}
	return code, nil
}

// redeem spends a code once.
func (l *linkCodes) redeem(code string, now time.Time) (string, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	hash := hashCode(code)
	entry, ok := l.codes[hash]
	if !ok {
		return "", false
	}
	delete(l.codes, hash)
	if now.After(entry.expires) {
		return "", false
	}
	return entry.accountID, true
}

// MARK: - Routes

type joinRequest struct {
	InviteCode string `json:"invite_code"`
	LinkCode   string `json:"link_code"`
	Label      string `json:"label"`
}

// joinHosted opens a hosted account with an invite code, or adds this Mac
// to one with a link code from another Mac.
func (s *Server) joinHosted(w http.ResponseWriter, r *http.Request) {
	if s.hosted == nil {
		writeError(w, http.StatusNotFound, "not_found_error", "This Saaa server doesn't offer hosted accounts. Connect your own Claude key instead.")
		return
	}
	now := s.now()
	if ok, wait := s.perAddress.Allow("join:"+s.clientAddress(r), now); !ok {
		rateLimited(w, wait)
		return
	}
	var body joinRequest
	if !decodeJSON(w, r, &body) {
		return
	}
	label := cleanLabel(body.Label)
	var (
		account *Account
		token   string
		joined  bool
		err     error
	)
	switch {
	case strings.TrimSpace(body.LinkCode) != "":
		accountID, ok := s.links.redeem(body.LinkCode, now)
		if !ok {
			writeError(w, http.StatusForbidden, "permission_error", "That link code didn't work. Make a new one on your other Mac; codes last ten minutes.")
			return
		}
		account, token, err = s.store.IssueToken(accountID, label, now)
		joined = true
	case strings.TrimSpace(body.InviteCode) != "":
		invite, redeemErr := RedeemInvite(s.dataDir, body.InviteCode, now)
		if redeemErr != nil {
			if errors.Is(redeemErr, ErrInviteInvalid) {
				writeError(w, http.StatusForbidden, "permission_error", "That invite code isn't valid or has been used.")
			} else {
				writeError(w, http.StatusInternalServerError, "api_error", "The server couldn't check the invite. Try again.")
			}
			return
		}
		account, token, err = s.store.CreateHosted(invite.Plan, invite.BudgetMicros, label, now)
	default:
		writeError(w, http.StatusBadRequest, "invalid_request_error", "Enter an invite code.")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "api_error", "The server couldn't open the account. Try again.")
		return
	}
	s.log.Info("hosted device connected", "account", short(account.ID), "joined_existing", joined)
	writeJSON(w, http.StatusOK, map[string]any{
		"token":           token,
		"account":         s.view(account),
		"joined_existing": joined,
		"verified_ms":     0,
	})
}

// link makes a one-time code another Mac can use to join this account.
func (s *Server) link(w http.ResponseWriter, r *http.Request) {
	account, _, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if !account.Hosted() {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "To add another Mac, connect it with the same Claude key.")
		return
	}
	code, err := s.links.create(account.ID, s.now())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "api_error", "The server couldn't make a code. Try again.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"link_code": code, "expires_in": int(linkCodeLifetime.Seconds())})
}

type usageView struct {
	Period           string    `json:"period"`
	Kind             string    `json:"kind"`
	Plan             string    `json:"plan,omitempty"`
	Requests         int64     `json:"requests"`
	InputTokens      int64     `json:"input_tokens"`
	OutputTokens     int64     `json:"output_tokens"`
	CacheReadTokens  int64     `json:"cache_read_tokens"`
	CacheWriteTokens int64     `json:"cache_write_tokens"`
	CostUSD          float64   `json:"cost_usd"`
	BudgetUSD        *float64  `json:"budget_usd"`
	RemainingUSD     *float64  `json:"remaining_usd"`
	ResetsAt         time.Time `json:"resets_at"`
}

// usage reports this month's counts and cost for the account, and for a
// hosted account its allowance.
func (s *Server) usage(w http.ResponseWriter, r *http.Request) {
	account, _, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	now := s.now()
	month := s.meter.Month(account.ID, now)
	view := usageView{
		Period:           period(now),
		Kind:             "byok",
		Plan:             account.Plan,
		Requests:         month.Requests,
		InputTokens:      month.InputTokens,
		OutputTokens:     month.OutputTokens,
		CacheReadTokens:  month.CacheReadTokens,
		CacheWriteTokens: month.CacheWrite5mTokens + month.CacheWrite1hTokens,
		CostUSD:          dollars(month.CostMicros),
		ResetsAt:         periodEnd(now),
	}
	if account.Hosted() {
		view.Kind = kindHosted
		budget := s.budget(account)
		remaining := max(0, budget-month.CostMicros)
		budgetUSD, remainingUSD := dollars(budget), dollars(remaining)
		view.BudgetUSD, view.RemainingUSD = &budgetUSD, &remainingUSD
	}
	writeJSON(w, http.StatusOK, view)
}

func dollars(micros int64) float64 { return float64(micros) / 1_000_000 }

func (s *Server) budget(account *Account) int64 {
	if account.BudgetMicros > 0 {
		return account.BudgetMicros
	}
	if s.hosted != nil {
		return s.hosted.BudgetMicros
	}
	return 0
}

// MARK: - Hosted requests

// hostedRequest is what the checks learned about a hosted request.
type hostedRequest struct {
	body  []byte
	model string
	// The reply's longest possible length, from the request.
	maxTokens int64
	// A rough prompt size from the body, for when no usage comes back.
	inputEstimate int64
	// Estimated cost held against the allowance while the request runs.
	reserved int64
}

// Requests that leave out max_tokens are refused by Anthropic; this only
// sizes the reservation.
const defaultMaxTokens = 4096

// hostedCheck runs before a hosted account's request reaches Anthropic:
// no beta features or server tools (they bill outside the token counts),
// an allowed model, and room in the month's allowance, where it holds the
// request's largest possible cost until the request is recorded. It
// buffers the body (already capped at maxBody) to read it and returns it
// for forwarding. Writes the error itself when the request can't go.
func (s *Server) hostedCheck(w http.ResponseWriter, r *http.Request, account *Account) (*hostedRequest, bool) {
	if s.hosted == nil {
		writeError(w, http.StatusForbidden, "permission_error", "Hosted accounts are turned off on this Saaa server.")
		return nil, false
	}
	if r.Header.Get("Anthropic-Beta") != "" {
		writeError(w, http.StatusForbidden, "permission_error", "Hosted accounts can't use beta features.")
		return nil, false
	}
	now := s.now()
	budget := s.budget(account)
	if r.Method != http.MethodPost {
		return &hostedRequest{}, true
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, s.maxBody))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "The request is too large for this server.")
		} else {
			writeError(w, http.StatusBadRequest, "invalid_request_error", "Bad request.")
		}
		return nil, false
	}
	var head struct {
		Model     string `json:"model"`
		MaxTokens int64  `json:"max_tokens"`
		Tools     []struct {
			Type string `json:"type"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(body, &head); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "The request body isn't valid JSON.")
		return nil, false
	}
	if !slices.Contains(s.hosted.Models, head.Model) {
		writeError(w, http.StatusForbidden, "permission_error",
			fmt.Sprintf("Hosted accounts can use %s. Pick one of those in Settings.", strings.Join(s.hosted.Models, " or ")))
		return nil, false
	}
	for _, tool := range head.Tools {
		if tool.Type != "" && tool.Type != "custom" {
			writeError(w, http.StatusForbidden, "permission_error", "Hosted accounts can't use Anthropic's server tools.")
			return nil, false
		}
	}
	request := &hostedRequest{body: body, model: head.Model, maxTokens: head.MaxTokens, inputEstimate: int64(len(body)) / 4}
	if request.maxTokens <= 0 {
		request.maxTokens = defaultMaxTokens
	}
	if r.URL.Path != "/v1/messages" {
		return request, true // counting tokens is free
	}
	estimate := costMicros(head.Model, Usage{InputTokens: request.inputEstimate, OutputTokens: request.maxTokens})
	if !s.meter.Reserve(account.ID, now, estimate, budget) {
		if s.meter.Month(account.ID, now).CostMicros >= budget {
			writeError(w, http.StatusPaymentRequired, "quota_exceeded",
				fmt.Sprintf("You've used this month's hosted allowance. It resets on %s.", periodEnd(now).Format("January 2")))
		} else {
			w.Header().Set("Retry-After", strconv.Itoa(2))
			writeError(w, http.StatusTooManyRequests, "rate_limit_error", "Your hosted allowance is busy with other requests. Try again in a moment.")
		}
		return nil, false
	}
	request.reserved = estimate
	return request, true
}
