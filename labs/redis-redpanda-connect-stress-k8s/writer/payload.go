package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Payload struct {
	EventID string `json:"event_id"`
	TsNs    int64  `json:"ts_ns"`
	Seq     int64  `json:"seq"`
	Pad     string `json:"pad"`
}

func NewPayload(seq int64, padBytes int) Payload {
	return Payload{
		EventID: uuid.NewString(),
		TsNs:    time.Now().UnixNano(),
		Seq:     seq,
		Pad:     strings.Repeat("x", padBytes),
	}
}

func (p Payload) JSON() ([]byte, error) {
	return json.Marshal(p)
}

// KeyValue represents one key-change event in the two real key patterns:
//
//	lp:m2g:active:employee:<id>            (pattern "m2g")
//	lp:r2g:active:tkms:<rule>#<role>       (pattern "r2g")
//
// Hash is the SHA-256 hex digest of "key:seq", simulating a content hash.
type KeyValue struct {
	Key     string
	Pattern string
	Hash    string
}

var (
	tkmsRules = []string{"pe_golden_rule", "comp_rule", "access_rule", "budget_rule", "hr_policy"}
	tkmsRoles = []string{"editor", "viewer", "admin", "owner"}
)

// NewKeyValue alternates between m2g and r2g patterns based on seq parity.
// employeeSpace controls how many distinct employee IDs exist in the m2g half.
func NewKeyValue(seq int64, employeeSpace int64) KeyValue {
	var key, pattern string
	if seq%2 == 0 {
		id := 10000 + (seq/2)%employeeSpace
		key = "lp:m2g:active:employee:" + strconv.FormatInt(id, 10)
		pattern = "m2g"
	} else {
		rule := tkmsRules[(seq/2)%int64(len(tkmsRules))]
		role := tkmsRoles[(seq/2)%int64(len(tkmsRoles))]
		key = "lp:r2g:active:tkms:" + rule + "#" + role
		pattern = "r2g"
	}
	h := sha256.Sum256([]byte(fmt.Sprintf("%s:%d", key, seq)))
	return KeyValue{Key: key, Pattern: pattern, Hash: hex.EncodeToString(h[:])}
}
