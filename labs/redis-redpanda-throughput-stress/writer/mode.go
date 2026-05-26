package main

import (
	"fmt"
	"sync/atomic"
)

type Mode int32

const (
	ModeBatch Mode = iota
	ModeSingle
)

type ModeStore struct {
	v atomic.Int32
}

func NewModeStore(initial string) *ModeStore {
	m := &ModeStore{}
	if initial == "single" {
		m.v.Store(int32(ModeSingle))
	} else {
		m.v.Store(int32(ModeBatch))
	}
	return m
}

func (m *ModeStore) Get() Mode { return Mode(m.v.Load()) }

func (m *ModeStore) Name() string {
	if m.Get() == ModeSingle {
		return "single"
	}
	return "batch"
}

func (m *ModeStore) SetByName(name string) error {
	switch name {
	case "batch":
		m.v.Store(int32(ModeBatch))
	case "single":
		m.v.Store(int32(ModeSingle))
	default:
		return fmt.Errorf("invalid mode %q: want batch|single", name)
	}
	return nil
}
