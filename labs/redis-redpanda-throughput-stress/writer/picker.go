package main

import (
	"fmt"
	"math/rand"
	"strconv"
	"strings"
)

const (
	PatternEmployee = 0
	PatternRole     = 1
	PatternOrg      = 2
)

type Picker struct {
	total int
	cum   [3]int
}

func ParsePatternWeights(s string) ([]int, error) {
	parts := strings.Split(s, ",")
	if len(parts) != 3 {
		return nil, fmt.Errorf("PATTERN_WEIGHTS must have 3 comma-separated values, got %d", len(parts))
	}
	w := make([]int, 3)
	sum := 0
	for i, p := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil {
			return nil, fmt.Errorf("PATTERN_WEIGHTS[%d] not a number: %q", i, p)
		}
		if n < 0 {
			return nil, fmt.Errorf("PATTERN_WEIGHTS[%d] negative: %d", i, n)
		}
		w[i] = n
		sum += n
	}
	if sum == 0 {
		return nil, fmt.Errorf("PATTERN_WEIGHTS all zero")
	}
	return w, nil
}

func NewPicker(weights []int) (*Picker, error) {
	if len(weights) != 3 {
		return nil, fmt.Errorf("NewPicker: need 3 weights, got %d", len(weights))
	}
	p := &Picker{}
	for i := 0; i < 3; i++ {
		p.total += weights[i]
		p.cum[i] = p.total
	}
	if p.total == 0 {
		return nil, fmt.Errorf("NewPicker: total weight is 0")
	}
	return p, nil
}

func (p *Picker) Pick(r *rand.Rand) int {
	n := r.Intn(p.total)
	switch {
	case n < p.cum[0]:
		return PatternEmployee
	case n < p.cum[1]:
		return PatternRole
	default:
		return PatternOrg
	}
}
