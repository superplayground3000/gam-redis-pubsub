package main

import (
	"encoding/json"
	"flag"
	"log"
	"os"
)

func main() {
	in := flag.String("in", "/dev/stdin", "sweep JSON input")
	out := flag.String("out", "report.html", "HTML output path")
	flag.Parse()

	raw, err := os.ReadFile(*in)
	if err != nil {
		log.Fatalf("read %s: %v", *in, err)
	}
	var s Sweep
	if err := json.Unmarshal(raw, &s); err != nil {
		log.Fatalf("parse sweep json: %v", err)
	}
	html, err := Render(s)
	if err != nil {
		log.Fatalf("render: %v", err)
	}
	if err := os.WriteFile(*out, []byte(html), 0o644); err != nil {
		log.Fatalf("write %s: %v", *out, err)
	}
	log.Printf("wrote %s (%d bytes)", *out, len(html))
}
