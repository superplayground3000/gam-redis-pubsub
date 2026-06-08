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

// Key renders lb:<domain>:<status>:{<entity>:<epoch>-<id>}. The hash tag
// {<entity>:<epoch>-<id>} is shared by the active and standby variants of one id,
// so an atomic dual-key rename lands on a single slot. The epoch isolates re-runs
// without flushing (region/srcmax start empty for a fresh epoch).
func (p Pattern) Key(status, epoch string, id int64) string {
	return fmt.Sprintf("lb:%s:%s:{%s:%s-%d}", p.Domain, status, p.Entity, epoch, id)
}
