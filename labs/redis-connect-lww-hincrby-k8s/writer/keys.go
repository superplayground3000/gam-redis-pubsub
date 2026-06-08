package main

import "fmt"

// Pattern is one of the three required key families.
type Pattern struct {
	Domain string // company | functions | general
	Entity string // employees | groups | items
}

// Patterns are the three required key families (lab-requirements.md §1).
var Patterns = []Pattern{
	{"company", "employees"},
	{"functions", "groups"},
	{"general", "items"},
}

// EntityID is the immutable per-entity identity shared by the active and standby
// variants of one id — used as the single version-counter field so all ops on an
// entity mint from one comparable monotonic sequence (design-decision-tree §9).
func (p Pattern) EntityID(epoch string, id int64) string {
	return fmt.Sprintf("%s:%s-%d", p.Entity, epoch, id)
}

// Key renders lb:<domain>:<status>:{<EntityID>}. The hash tag (EntityID) is shared
// by the active and standby variants of one id, so an atomic dual-key rename lands
// on a single slot. Key is built FROM EntityID so the key's tag and the version
// counter field can never drift. The epoch isolates re-runs without flushing
// (region/srcmax start empty for a fresh epoch).
func (p Pattern) Key(status, epoch string, id int64) string {
	return fmt.Sprintf("lb:%s:%s:{%s}", p.Domain, status, p.EntityID(epoch, id))
}
