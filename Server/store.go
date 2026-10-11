package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Account is one bring-your-own-key owner. The API key is only ever held
// sealed (AES-256-GCM); the fingerprint lets another device with the same
// key join the account.
type Account struct {
	ID          string    `json:"id"`
	Fingerprint string    `json:"key_fingerprint"`
	KeyHint     string    `json:"key_hint"`
	SealedKey   string    `json:"key_sealed"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// Token is one device's access. Only its SHA-256 hash is stored.
type Token struct {
	Hash       string    `json:"hash"`
	AccountID  string    `json:"account_id"`
	Label      string    `json:"label,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
	LastUsedAt time.Time `json:"last_used_at"`
}

type storeFile struct {
	Version  int        `json:"version"`
	Accounts []*Account `json:"accounts"`
	Tokens   []*Token   `json:"tokens"`
}

var (
	ErrNotFound     = errors.New("not found")
	ErrKeyInUse     = errors.New("that key belongs to another account")
	errStoreVersion = errors.New("unsupported store version")
)

// Store keeps accounts and tokens in memory and in data/accounts.json
// (mode 0600, written atomically). Lookups never touch the disk.
type Store struct {
	mu       sync.RWMutex
	path     string
	accounts map[string]*Account // by id
	byPrint  map[string]*Account // by key fingerprint
	tokens   map[string]*Token   // by token hash
	dirty    bool                // last-used times changed since the last write
}

func OpenStore(dataDir string) (*Store, error) {
	s := &Store{
		path:     filepath.Join(dataDir, "accounts.json"),
		accounts: map[string]*Account{},
		byPrint:  map[string]*Account{},
		tokens:   map[string]*Token{},
	}
	raw, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	var file storeFile
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, err
	}
	if file.Version != 1 {
		return nil, errStoreVersion
	}
	for _, a := range file.Accounts {
		s.accounts[a.ID] = a
		s.byPrint[a.Fingerprint] = a
	}
	for _, t := range file.Tokens {
		if _, ok := s.accounts[t.AccountID]; ok {
			s.tokens[t.Hash] = t
		}
	}
	return s, nil
}

// Register finds the account for a key (by fingerprint) or creates one,
// then issues a token for this device.
func (s *Store) Register(keys *Keys, apiKey, label string, now time.Time) (*Account, string, bool, error) {
	token, hash, err := NewToken()
	if err != nil {
		return nil, "", false, err
	}
	fp := keys.Fingerprint(apiKey)

	s.mu.Lock()
	defer s.mu.Unlock()
	account, existed := s.byPrint[fp]
	if !existed {
		id := NewID("acct")
		sealed, err := keys.Seal(apiKey, id)
		if err != nil {
			return nil, "", false, err
		}
		account = &Account{
			ID: id, Fingerprint: fp, KeyHint: KeyHint(apiKey), SealedKey: sealed,
			CreatedAt: now, UpdatedAt: now,
		}
		s.accounts[id] = account
		s.byPrint[fp] = account
	}
	s.tokens[hash] = &Token{Hash: hash, AccountID: account.ID, Label: label, CreatedAt: now, LastUsedAt: now}
	if err := s.saveLocked(); err != nil {
		return nil, "", false, err
	}
	snapshot := *account
	return &snapshot, token, existed, nil
}

// Authenticate resolves a bearer token to its account and records use.
func (s *Store) Authenticate(token string, now time.Time) (*Account, *Token, bool) {
	hash := HashToken(token)
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tokens[hash]
	if !ok || !SameHash(t.Hash, hash) {
		return nil, nil, false
	}
	account, ok := s.accounts[t.AccountID]
	if !ok {
		return nil, nil, false
	}
	if now.Sub(t.LastUsedAt) > time.Minute {
		t.LastUsedAt = now
		s.dirty = true
	}
	accountCopy, tokenCopy := *account, *t
	return &accountCopy, &tokenCopy, true
}

// ReplaceKey reseals a new key for an account.
func (s *Store) ReplaceKey(keys *Keys, accountID, apiKey string, now time.Time) (*Account, error) {
	fp := keys.Fingerprint(apiKey)
	s.mu.Lock()
	defer s.mu.Unlock()
	account, ok := s.accounts[accountID]
	if !ok {
		return nil, ErrNotFound
	}
	if other, taken := s.byPrint[fp]; taken && other.ID != accountID {
		return nil, ErrKeyInUse
	}
	sealed, err := keys.Seal(apiKey, accountID)
	if err != nil {
		return nil, err
	}
	delete(s.byPrint, account.Fingerprint)
	account.Fingerprint = fp
	account.KeyHint = KeyHint(apiKey)
	account.SealedKey = sealed
	account.UpdatedAt = now
	s.byPrint[fp] = account
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	snapshot := *account
	return &snapshot, nil
}

// DeleteAccount removes an account, its sealed key and every device token.
func (s *Store) DeleteAccount(accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	account, ok := s.accounts[accountID]
	if !ok {
		return ErrNotFound
	}
	delete(s.accounts, accountID)
	delete(s.byPrint, account.Fingerprint)
	for hash, t := range s.tokens {
		if t.AccountID == accountID {
			delete(s.tokens, hash)
		}
	}
	return s.saveLocked()
}

// RevokeToken signs one device out; the account and its key stay.
func (s *Store) RevokeToken(token string) error {
	hash := HashToken(token)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tokens[hash]; !ok {
		return ErrNotFound
	}
	delete(s.tokens, hash)
	return s.saveLocked()
}

// Devices counts the tokens for an account.
func (s *Store) Devices(accountID string) int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for _, t := range s.tokens {
		if t.AccountID == accountID {
			n++
		}
	}
	return n
}

// FlushIfDirty persists last-used times (called periodically).
func (s *Store) FlushIfDirty() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.dirty {
		return nil
	}
	return s.saveLocked()
}

func (s *Store) saveLocked() error {
	file := storeFile{Version: 1}
	for _, a := range s.accounts {
		file.Accounts = append(file.Accounts, a)
	}
	for _, t := range s.tokens {
		file.Tokens = append(file.Tokens, t)
	}
	raw, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	if err := writeFileAtomic(s.path, raw, 0o600); err != nil {
		return err
	}
	s.dirty = false
	return nil
}
