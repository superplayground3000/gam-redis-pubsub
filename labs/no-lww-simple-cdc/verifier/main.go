// $LAB/verifier/main.go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"time"
)

func main() {
	epoch := flag.String("epoch", "", "unique per-run epoch token (required)")
	central := flag.String("redis-central", "redis-central:6379", "central Redis host:port")
	region := flag.String("redis-region", "redis-region:6379", "region Redis host:port")
	natsURL := flag.String("nats", "http://nats:8222", "NATS monitoring URL")
	stream := flag.String("nats-stream", "KV_CDC", "JetStream stream name")
	// --nats-consumer is accepted (the verifier Job passes --nats-consumer=cdc_sink)
	// but intentionally discarded: quiescence keys off stream-wide MaxPending, which
	// equals the sink durable's pending because KV_CDC has exactly one JetStream
	// consumer. The value is informational only — not an oversight.
	_ = flag.String("nats-consumer", "cdc_sink", "sink durable name (informational)")
	sourceGroup := flag.String("source-group", "cdc_propagator", "source consumer group")
	quiesce := flag.Duration("quiesce-timeout", 15*time.Second, "per-op quiescence deadline")
	flag.Parse()

	if *epoch == "" {
		log.Fatal("--epoch is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	centralC := NewRedisClient(*central)
	defer centralC.Close()
	regionC := NewRedisClient(*region)
	defer regionC.Close()

	checks := &Checks{Central: centralC, Region: regionC, NatsURL: *natsURL, Stream: *stream, SourceGroup: *sourceGroup, Quiesce: *quiesce}

	res := CDCResult{Epoch: *epoch}

	delta, dok, err := checks.Dedup(ctx, *epoch)
	if err != nil {
		log.Printf("dedup error: %v", err)
	}
	res.DedupDelta, res.DedupOK = delta, dok

	cOK, uOK, rOK, dOK, err := checks.PerOp(ctx, *epoch)
	if err != nil {
		log.Printf("per-op error: %v", err)
	}
	res.CreateOK, res.UpdateOK, res.RenameOK, res.DeleteOK = cOK, uOK, rOK, dOK
	res.OpsOK = cOK && uOK && rOK && dOK

	rok, err := checks.Replay(ctx, *epoch)
	if err != nil {
		log.Printf("replay error: %v", err)
	}
	res.ReplayOK = rok

	pok, err := checks.RenameParity(ctx, *epoch)
	if err != nil {
		log.Printf("rename-parity error: %v", err)
	}
	res.RenameParityOK = pok

	rep := Report{CDC: res, Verdict: ComputeVerdict(res)}
	b, _ := json.Marshal(rep)
	fmt.Printf("RESULT_JSON:%s\n", b)
	log.Printf("verdict.pass=%v reason=%q dedup_delta=%d ops_ok=%v replay_ok=%v rename_parity_ok=%v",
		rep.Verdict.Pass, rep.Verdict.Reason, res.DedupDelta, res.OpsOK, res.ReplayOK, res.RenameParityOK)
}
