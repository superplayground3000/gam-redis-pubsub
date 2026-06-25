package main

import (
	"strconv"
	"strings"
)

// RenderPipeline substitutes the literal __SLEEP_MS__ / __THREADS__ placeholders.
// We substitute in the controller (not via env interpolation) because the streams
// REST API does NOT expand environment variables in POSTed configs.
func RenderPipeline(tmpl string, sleepMS, threads int) string {
	return strings.NewReplacer(
		"__SLEEP_MS__", itoa(sleepMS),
		"__THREADS__", itoa(threads),
	).Replace(tmpl)
}

func itoa(n int) string { return strconv.Itoa(n) }
