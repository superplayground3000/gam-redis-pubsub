// $LAB/writer/patterns.go
package main

import "fmt"

// Pattern is one of the three required key families. The hash tag is the
// {entity:id} segment so a multi-key rename Lua stays in a single Redis slot.
// "funtions" spelling is verbatim from lab-requirements.md and intentional.
type Pattern struct {
	Name   string // short label for metrics/state: company|funtions|general
	active string // fmt with one %d (the id)
	stby   string // standby fmt; SAME {entity:id} hash tag as active
}

func (p Pattern) ActiveKey(id int64) string  { return fmt.Sprintf(p.active, id) }
func (p Pattern) StandbyKey(id int64) string { return fmt.Sprintf(p.stby, id) }
func (p Pattern) HasStandby() bool           { return p.stby != "" }

// Patterns is the fixed set from lab-requirements.md "Key naming pattern". Every
// pattern has BOTH an active and a standby form sharing the {entity:id} hash tag,
// so the standby->active rename (a value-preserving Redis RENAME) keeps both keys
// in one slot on Redis Cluster. The generator stages and edits each entity on its
// standby key (create/update) and promotes it to active (rename); active is written
// only by promotion. See worker.buildEvent.
var Patterns = []Pattern{
	{Name: "company", active: "lb:company:active:{employees:%d}", stby: "lb:company:standby:{employees:%d}"},
	{Name: "funtions", active: "lb:funtions:active:{groups:%d}", stby: "lb:funtions:standby:{groups:%d}"},
	{Name: "general", active: "lb:general:active:{items:%d}", stby: "lb:general:standby:{items:%d}"},
}
