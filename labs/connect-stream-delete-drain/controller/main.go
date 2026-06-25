package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	cfg := LoadConfig(os.Getenv)
	if err := run(cfg); err != nil {
		log.Fatalf("run: %v", err)
	}
}

func run(cfg Config) error {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	tmpl, err := os.ReadFile("/etc/connect/pipeline.tmpl.yaml")
	if err != nil {
		return fmt.Errorf("read template: %w", err)
	}
	pipeline := RenderPipeline(string(tmpl), cfg.SleepMS, cfg.PipelineThreads)

	connect := newConnectClient(cfg.ConnectAddr)
	if err := waitConnectReady(ctx, connect); err != nil {
		return err
	}

	sink := newSinkReader(cfg.RedisAddr)
	defer sink.close()
	if err := sink.flush(ctx); err != nil {
		return fmt.Errorf("flush redis: %w", err)
	}

	js, err := dialJetStream(ctx, cfg.NATSURL)
	if err != nil {
		return err
	}
	defer js.close()
	if err := js.setup(ctx, cfg.AckWait, cfg.MaxAckPending); err != nil {
		return err
	}

	log.Printf("publishing %d messages (rate=%d)", cfg.MsgCount, cfg.PublishRate)
	if err := js.publish(ctx, cfg.MsgCount, cfg.PublishRate); err != nil {
		return err
	}

	log.Printf("POST stream %q", cfg.StreamID)
	if err := connect.PostStream(ctx, cfg.StreamID, pipeline); err != nil {
		return err
	}

	inflightAtDelete, err := armAndDelete(ctx, cfg, connect, sink, js)
	if err != nil {
		return err
	}

	log.Printf("re-POST stream %q (new leader drains remainder)", cfg.StreamID)
	if err := connect.PostStream(ctx, cfg.StreamID, pipeline); err != nil {
		return err
	}

	if err := waitQuiescent(ctx, js); err != nil {
		return err
	}

	applied, err := sink.readLedger(ctx, cfg.MsgCount)
	if err != nil {
		return err
	}
	cs, err := js.consumerState(ctx)
	if err != nil {
		return err
	}

	v := Reconcile(cfg.Profile, cfg.MsgCount, inflightAtDelete, applied, cs)
	out, _ := json.Marshal(v)
	fmt.Printf("RESULT_JSON %s\n", out)
	if !v.Verdict.Pass {
		return fmt.Errorf("VERDICT FAIL: lost=%v drained=%v inflight_at_delete=%d",
			v.Lost, v.Drained, v.InflightAtDelete)
	}
	log.Printf("VERDICT PASS: n=%d dup=%d inflight_at_delete=%d", v.N, v.DupCount, inflightAtDelete)
	return nil
}

func waitConnectReady(ctx context.Context, c *connectClient) error {
	for i := 0; i < 60; i++ {
		if c.Ready(ctx) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return fmt.Errorf("connect not ready after 60s")
}

// armAndDelete polls until the arm predicate fires, snapshots the in-flight cohort
// (num_ack_pending), then DELETEs the stream. Returns inflight-at-delete.
func armAndDelete(ctx context.Context, cfg Config, connect *connectClient, sink *sinkReader, js *jsClient) (int, error) {
	deadline := time.After(2 * time.Minute)
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-deadline:
			return 0, fmt.Errorf("arm condition never met")
		case <-tick.C:
		}
		cs, err := js.consumerState(ctx)
		if err != nil {
			return 0, err
		}
		distinct, err := sink.distinctApplied(ctx)
		if err != nil {
			return 0, err
		}
		in := ArmInput{
			Profile: cfg.Profile, N: cfg.MsgCount, ArmFraction: cfg.ArmFraction,
			ArmInflight: cfg.ArmInflight, AppliedDistinct: distinct, NumAckPending: cs.NumAckPending,
		}
		if Armed(in) {
			log.Printf("ARMED: distinct=%d num_ack_pending=%d -> DELETE", distinct, cs.NumAckPending)
			if err := connect.DeleteStream(ctx, cfg.StreamID); err != nil {
				return 0, err
			}
			return cs.NumAckPending, nil
		}
	}
}

// waitQuiescent waits for num_pending==0 && num_ack_pending==0, stable across 3
// consecutive polls (the parent lab's lesson: lag drops before the ack lands).
func waitQuiescent(ctx context.Context, js *jsClient) error {
	deadline := time.After(3 * time.Minute)
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	stable := 0
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline:
			return fmt.Errorf("never quiesced")
		case <-tick.C:
		}
		cs, err := js.consumerState(ctx)
		if err != nil {
			return err
		}
		if cs.NumPending == 0 && cs.NumAckPending == 0 {
			if stable++; stable >= 3 {
				return nil
			}
		} else {
			stable = 0
		}
	}
}
