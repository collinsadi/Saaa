package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Keys holds the two subkeys derived from the server's master key: one
// seals API keys at rest, one fingerprints them so a second device with the
// same key joins the same account. The master key never leaves the data
// directory and is never logged.
type Keys struct {
	seal        cipher.AEAD
	fingerprint []byte
}

// LoadOrCreateMasterKey reads data/master.key, creating 32 random bytes
// (mode 0600) on first start.
func LoadOrCreateMasterKey(dataDir string) ([]byte, error) {
	path := filepath.Join(dataDir, "master.key")
	key, err := os.ReadFile(path)
	if err == nil {
		if len(key) != 32 {
			return nil, fmt.Errorf("%s: expected 32 bytes, found %d", path, len(key))
		}
		return key, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	key = make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	if err := writeFileAtomic(path, key, 0o600); err != nil {
		return nil, err
	}
	return key, nil
}

// DeriveKeys splits the master key with HKDF-SHA256 (RFC 5869).
func DeriveKeys(master []byte) (*Keys, error) {
	if len(master) != 32 {
		return nil, errors.New("master key must be 32 bytes")
	}
	sealKey := hkdf(master, []byte("saaa-relay"), []byte("seal api keys v1"))
	block, err := aes.NewCipher(sealKey)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Keys{
		seal:        aead,
		fingerprint: hkdf(master, []byte("saaa-relay"), []byte("fingerprint api keys v1")),
	}, nil
}

// hkdf derives 32 bytes: one HKDF-Expand block is exactly SHA-256's size.
func hkdf(secret, salt, info []byte) []byte {
	extract := hmac.New(sha256.New, salt)
	extract.Write(secret)
	prk := extract.Sum(nil)
	expand := hmac.New(sha256.New, prk)
	expand.Write(info)
	expand.Write([]byte{1})
	return expand.Sum(nil)
}

// Seal encrypts an API key, bound to its account id.
func (k *Keys) Seal(plaintext, accountID string) (string, error) {
	nonce := make([]byte, k.seal.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := k.seal.Seal(nonce, nonce, []byte(plaintext), []byte(accountID))
	return base64.StdEncoding.EncodeToString(sealed), nil
}

// Open decrypts a sealed API key; it fails if the record was moved to
// another account or tampered with.
func (k *Keys) Open(sealed, accountID string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		return "", err
	}
	size := k.seal.NonceSize()
	if len(raw) < size {
		return "", errors.New("sealed key too short")
	}
	plain, err := k.seal.Open(nil, raw[:size], raw[size:], []byte(accountID))
	if err != nil {
		return "", err
	}
	return string(plain), nil
}

// Fingerprint identifies an API key without storing it.
func (k *Keys) Fingerprint(apiKey string) string {
	mac := hmac.New(sha256.New, k.fingerprint)
	mac.Write([]byte(apiKey))
	return hex.EncodeToString(mac.Sum(nil))
}

// NewToken returns a device access token and the hash the store keeps.
func NewToken() (token, hash string, err error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", "", err
	}
	token = "saaa_" + base64.RawURLEncoding.EncodeToString(raw)
	return token, HashToken(token), nil
}

// HashToken is how tokens are stored and looked up.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// NewID returns a short random identifier with a prefix.
func NewID(prefix string) string {
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return prefix + "_" + base64.RawURLEncoding.EncodeToString(raw)
}

// SameHash compares two hex hashes in constant time.
func SameHash(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// LooksLikeAnthropicKey is a cheap shape check before calling Anthropic.
func LooksLikeAnthropicKey(key string) bool {
	return strings.HasPrefix(key, "sk-ant-") && len(key) >= 40 && len(key) <= 300 &&
		!strings.ContainsAny(key, " \t\r\n")
}

// KeyHint is safe to show: sk-ant-…a1B2.
func KeyHint(key string) string {
	if len(key) < 12 {
		return "sk-ant-…"
	}
	return "sk-ant-…" + key[len(key)-4:]
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
