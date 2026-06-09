package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"

	"golang.org/x/crypto/hkdf"
	"golang.org/x/crypto/nacl/secretbox"
)

// codeAlphabet is RFC-4648 base32 without padding (A–Z, 2–7). Human typeable and
// unambiguous enough for a short shared secret.
var codeEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// grantKeys are everything a grant code expands into. Host and guest derive the
// exact same values from the same code.
type grantKeys struct {
	roomID      string   // Nostr "#d" topic both parties meet in
	announceKey [32]byte // secretbox key for presence + signaling
	channelKey  [32]byte // secretbox key for data-channel auth
}

// newGrantCode generates a fresh 16-byte secret and returns its canonical
// (compact, no-dash) string form.
func newGrantCode() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return codeEncoding.EncodeToString(b), nil
}

// normalizeCode strips formatting (the "VS-" display prefix, dashes, spaces,
// case) so the dashed display form and the compact form both decode to the
// same bytes.
func normalizeCode(code string) string {
	s := strings.TrimSpace(code)
	// Remove the display-only "VS-" prefix (always written with a dash, which
	// the raw base32 body never contains).
	if len(s) >= 3 && strings.EqualFold(s[:3], "VS-") {
		s = s[3:]
	}
	r := strings.NewReplacer("-", "", " ", "", "\t", "", "\n", "")
	return strings.ToUpper(r.Replace(s))
}

// formatCode renders a code for humans: VS-XXXX-XXXX-XXXX-XXXX...
func formatCode(code string) string {
	c := normalizeCode(code)
	var parts []string
	for i := 0; i < len(c); i += 4 {
		end := i + 4
		if end > len(c) {
			end = len(c)
		}
		parts = append(parts, c[i:end])
	}
	return "VS-" + strings.Join(parts, "-")
}

// deriveGrantKeys expands a grant code into its room ID and symmetric keys.
func deriveGrantKeys(code string) (grantKeys, error) {
	raw, err := codeEncoding.DecodeString(normalizeCode(code))
	if err != nil {
		return grantKeys{}, fmt.Errorf("invalid grant code: %w", err)
	}
	if len(raw) < 16 {
		return grantKeys{}, fmt.Errorf("grant code too short")
	}

	roomBytes := hkdfBytes(raw, "vibeshare-grant-room-v1", 16)
	var keys grantKeys
	keys.roomID = base64.RawURLEncoding.EncodeToString(roomBytes)
	copy(keys.announceKey[:], hkdfBytes(raw, "vibeshare-grant-announce-v1", 32))
	copy(keys.channelKey[:], hkdfBytes(raw, "vibeshare-grant-channel-v1", 32))
	return keys, nil
}

func hkdfBytes(secret []byte, info string, n int) []byte {
	r := hkdf.New(sha256.New, secret, nil, []byte(info))
	out := make([]byte, n)
	if _, err := io.ReadFull(r, out); err != nil {
		panic(err) // hkdf.Reader never errors for sane lengths
	}
	return out
}

// sealJSON marshals v and seals it with secretbox; the nonce is prepended.
func sealJSON(key [32]byte, v any) (string, error) {
	plain, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", err
	}
	sealed := secretbox.Seal(nonce[:], plain, &nonce, &key)
	return base64.StdEncoding.EncodeToString(sealed), nil
}

// openJSON reverses sealJSON into out. Returns false if the key is wrong.
func openJSON(key [32]byte, b64 string, out any) bool {
	sealed, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(sealed) < 24+secretbox.Overhead {
		return false
	}
	var nonce [24]byte
	copy(nonce[:], sealed[:24])
	plain, ok := secretbox.Open(nil, sealed[24:], &nonce, &key)
	if !ok {
		return false
	}
	return json.Unmarshal(plain, out) == nil
}

// freshTimestamp reports whether ts (unix seconds) is within tolerance of now,
// used to reject replayed auth/presence frames.
func freshTimestamp(ts int64, tolerance time.Duration) bool {
	delta := time.Now().Unix() - ts
	if delta < 0 {
		delta = -delta
	}
	return time.Duration(delta)*time.Second <= tolerance
}
