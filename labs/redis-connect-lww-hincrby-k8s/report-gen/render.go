package main

import (
	"bytes"
	_ "embed"
	"html/template"
)

// Tier holds the result for a single throughput tier in the sweep.
type Tier struct {
	Rate       int   `json:"rate"`
	Pass       bool  `json:"pass"`
	Mismatches int   `json:"mismatches"`
	Stale      int64 `json:"stale"`
	Applied    int64 `json:"applied"`
	Duplicate  int64 `json:"duplicate"`
	Tombstones int   `json:"tombstones"`
}

// Proof holds the result of a correctness proof scenario.
type Proof struct {
	Name string `json:"name"`
	Pass bool   `json:"pass"`
}

// Sweep is the top-level structure produced by the gc-sweeper.
type Sweep struct {
	Lab            string  `json:"lab"`
	MaxPassingTier int     `json:"max_passing_tier"`
	Tiers          []Tier  `json:"tiers"`
	Proofs         []Proof `json:"proofs"`
}

//go:embed templates/report.html.tmpl
var reportTmpl string

// barWidth returns a pixel width (0–120) proportional to applied, capped at 120.
func barWidth(applied int64) int64 {
	const max = 120
	const scale = 4000 // applied=4000 → 120px; linear below that
	if applied <= 0 {
		return 0
	}
	w := applied * max / scale
	if w > max {
		return max
	}
	return w
}

// safeText returns a template.HTML from a plain string so that html/template
// does not double-escape characters like '+' that are safe in display context.
// The input is an application-controlled identifier (proof name, lab name)
// and never contains raw user HTML.
func safeText(s string) template.HTML {
	return template.HTML(template.HTMLEscapeString(s))
}

// Render executes the HTML template against s and returns the rendered string.
func Render(s Sweep) (string, error) {
	funcMap := template.FuncMap{
		"barWidth": barWidth,
		"safe":     safeText,
	}
	t, err := template.New("report").Funcs(funcMap).Parse(reportTmpl)
	if err != nil {
		return "", err
	}
	var b bytes.Buffer
	if err := t.Execute(&b, s); err != nil {
		return "", err
	}
	return b.String(), nil
}
