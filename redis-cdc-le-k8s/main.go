// redis-cdc-le-k8s mono binary: one module, one build, one image. The first
// argument selects which lab workload to run; each k8s manifest sets
// `command: [".../app","<mode>"]`. Remaining args are forwarded to the workload
// (only `verifier` parses flags; the others are env-driven and ignore them).
package main

import (
	"fmt"
	"os"

	"redis-cdc-le-k8s/internal/dashboard"
	"redis-cdc-le-k8s/internal/elector"
	"redis-cdc-le-k8s/internal/latency"
	"redis-cdc-le-k8s/internal/verifier"
	"redis-cdc-le-k8s/internal/writer"
)

func usage() {
	fmt.Fprint(os.Stderr, "usage: app <mode> [args]\n\nmodes:\n"+
		"  writer\n  verifier\n  elector\n  latency-calculator\n  dashboard\n")
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	mode, args := os.Args[1], os.Args[2:]
	switch mode {
	case "writer":
		writer.Run(args)
	case "verifier":
		verifier.Run(args)
	case "elector":
		elector.Run(args)
	case "latency-calculator":
		latency.Run(args)
	case "dashboard":
		dashboard.Run(args)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode %q\n", mode)
		usage()
		os.Exit(2)
	}
}
