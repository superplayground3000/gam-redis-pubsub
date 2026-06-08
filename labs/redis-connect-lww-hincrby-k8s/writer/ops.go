package main

import "math/rand"

type Op string

const (
	OpSet    Op = "set"
	OpDelete Op = "delete"
	OpRename Op = "rename" // standby -> active
)

type OpWeights struct{ Set, Delete, Rename int }

// OpPicker is a weighted random selector over the three op types.
type OpPicker struct {
	cum   []int
	ops   []Op
	total int
	rnd   *rand.Rand
}

func NewOpPicker(w OpWeights, rnd *rand.Rand) *OpPicker {
	p := &OpPicker{rnd: rnd}
	add := func(op Op, wt int) {
		if wt <= 0 {
			return
		}
		p.total += wt
		p.cum = append(p.cum, p.total)
		p.ops = append(p.ops, op)
	}
	add(OpSet, w.Set)
	add(OpDelete, w.Delete)
	add(OpRename, w.Rename)
	return p
}

func (p *OpPicker) Pick() Op {
	if p.total == 0 {
		return OpSet
	}
	r := p.rnd.Intn(p.total)
	for i, c := range p.cum {
		if r < c {
			return p.ops[i]
		}
	}
	return p.ops[len(p.ops)-1]
}
