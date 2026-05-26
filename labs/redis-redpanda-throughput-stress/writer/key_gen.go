package main

import (
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/rand"
)

type KeyGenConfig struct {
	Cardinality int
	Seed        int64
}

type KeyGen struct {
	cardinality int
	rolePool    []string
}

func NewKeyGen(cfg KeyGenConfig) *KeyGen {
	g := &KeyGen{cardinality: cfg.Cardinality}
	g.rolePool = make([]string, cfg.Cardinality)
	r := rand.New(rand.NewSource(cfg.Seed))
	var buf [8]byte
	h := sha1.New()
	for i := 0; i < cfg.Cardinality; i++ {
		binary.LittleEndian.PutUint64(buf[:], r.Uint64())
		h.Reset()
		h.Write(buf[:])
		g.rolePool[i] = hex.EncodeToString(h.Sum(nil))
	}
	return g
}

func (g *KeyGen) Employee(id int) string {
	return fmt.Sprintf("lb:company:active:{employee:%d}", id)
}

func (g *KeyGen) Org(id int) string {
	return fmt.Sprintf("lb:functions:active:{org:%d}", id)
}

func (g *KeyGen) Role(idx int) string {
	return fmt.Sprintf("lb:functions:active:{role:%s}", g.rolePool[idx%g.cardinality])
}

func (g *KeyGen) Cardinality() int { return g.cardinality }
