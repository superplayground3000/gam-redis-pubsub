package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: harness <publish|verify|cinfo|wait-inflight>")
		os.Exit(2)
	}
	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	switch cmd {
	case "publish":
		count := fs.Int("count", 0, "distinct keys kv:1..N")
		faultEvery := fs.Int("fault-every", 0, "mark every Nth key fault_mode=first")
		key := fs.String("key", "", "single control key index")
		fault := fs.String("fault", "none", "control fault_mode: none|first|always")
		_ = fs.Parse(os.Args[2:])
		cmdPublish(*count, *faultEvery, *key, *fault)
	case "verify":
		count := fs.Int("count", 0, "expected keys")
		_ = fs.Parse(os.Args[2:])
		cmdVerify(*count)
	case "cinfo":
		field := fs.String("field", "", "num_ack_pending|num_pending|delivered|ack_floor|''")
		_ = fs.Parse(os.Args[2:])
		cmdCinfo(*field)
	case "wait-inflight":
		target := fs.Int("target", 1, "num_ack_pending target")
		timeout := fs.Int("timeout", 15, "seconds")
		_ = fs.Parse(os.Args[2:])
		cmdWaitInflight(*target, *timeout)
	default:
		fmt.Fprintln(os.Stderr, "unknown command:", cmd)
		os.Exit(2)
	}
}
