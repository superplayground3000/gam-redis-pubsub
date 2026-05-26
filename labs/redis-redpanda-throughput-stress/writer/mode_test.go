package main

import (
	"sync"
	"testing"
)

func TestModeStore_DefaultBatch(t *testing.T) {
	m := NewModeStore("batch")
	if m.Get() != ModeBatch {
		t.Fatalf("default Get() = %v, want ModeBatch", m.Get())
	}
}

func TestModeStore_SetGet(t *testing.T) {
	m := NewModeStore("batch")
	if err := m.SetByName("single"); err != nil {
		t.Fatalf("SetByName(single): %v", err)
	}
	if m.Get() != ModeSingle {
		t.Fatalf("after SetByName(single), Get() = %v, want ModeSingle", m.Get())
	}
}

func TestModeStore_RejectInvalid(t *testing.T) {
	m := NewModeStore("batch")
	if err := m.SetByName("yolo"); err == nil {
		t.Fatal("SetByName(yolo) should error")
	}
}

func TestModeStore_ConcurrentReadWriteRaceClean(t *testing.T) {
	m := NewModeStore("batch")
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				if i%2 == 0 {
					_ = m.Get()
				} else {
					name := "batch"
					if j%2 == 0 {
						name = "single"
					}
					_ = m.SetByName(name)
				}
			}
		}(i)
	}
	wg.Wait()
}

func TestModeStore_NameRoundTrip(t *testing.T) {
	m := NewModeStore("single")
	if m.Name() != "single" {
		t.Fatalf("Name() = %q, want single", m.Name())
	}
	_ = m.SetByName("batch")
	if m.Name() != "batch" {
		t.Fatalf("after SetByName(batch), Name() = %q, want batch", m.Name())
	}
}
