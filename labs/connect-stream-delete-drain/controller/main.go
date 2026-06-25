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
	pipeline := RenderPipeline(string(tmpl), cfg.SleepMS, cfg.PipelineThreads, cfg.MaxAckPending)

	connect := newConnectClient(cfg.ConnectAddr)
	if err := waitConnectReady(ctx, connect); err != nil {
		return err
	}
	// Clean slate: delete any leftover stream from a previous run (idempotent; 404 is OK).
	if err := connect.DeleteStream(ctx, cfg.StreamID); err != nil {
		return fmt.Errorf("pre-run cleanup: %w", err)
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

// armAndDelete polls until the arm predicate fires, then does a SECOND confirm-poll
// after a short delay to verify the cohort is still stably parked (not draining
// away between the first poll and the DELETE reaching Connect). Only after both
// polls show NumAckPending >= MinInflight does it fire the DELETE.
//
// confirmDelay = max(20ms, min(SLEEP_MS/4, 100ms)) — long enough to detect a
// draining cohort, short enough to stay inside the sleep window.
//
// inflight_at_delete is set from the SECOND (confirm) poll — the value closest
// to the actual DELETE moment and conservative (may be slightly lower).
func armAndDelete(ctx context.Context, cfg Config, connect *connectClient, sink *sinkReader, js *jsClient) (int, error) {
	// Compute confirm-poll delay: SLEEP_MS/4, clamped to [20ms, 100ms].
	confirmDelay := time.Duration(cfg.SleepMS/4) * time.Millisecond
	if confirmDelay < 20*time.Millisecond {
		confirmDelay = 20 * time.Millisecond
	}
	if confirmDelay > 100*time.Millisecond {
		confirmDelay = 100 * time.Millisecond
	}

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
			ArmInflight: cfg.ArmInflight, MinInflight: cfg.MinInflight,
			AppliedDistinct: distinct,
			NumAckPending:   cs.NumAckPending, NumPending: int(cs.NumPending),
		}
		if !Armed(in) {
			continue
		}

		// First poll armed. Wait confirmDelay, then confirm the cohort is still
		// stably parked (not draining away in the gap before DELETE arrives).
		log.Printf("ARMED (first poll): distinct=%d num_pending=%d num_ack_pending=%d; confirming in %s...",
			distinct, cs.NumPending, cs.NumAckPending, confirmDelay)
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-time.After(confirmDelay):
		}

		cs2, err := js.consumerState(ctx)
		if err != nil {
			return 0, err
		}
		// Build confirm input: reuse the same backlog/distinct snapshot (unchanged
		// during confirmDelay) but refresh NumAckPending/NumPending from cs2.
		in2 := in
		in2.NumAckPending = cs2.NumAckPending
		in2.NumPending = int(cs2.NumPending)
		if !Armed(in2) {
			// Cohort drained below MinInflight between first and confirm poll:
			// the sleep window closed before DELETE would land. Keep polling.
			log.Printf("CONFIRM FAILED: num_ack_pending dropped to %d (< min_inflight=%d); re-arming...",
				cs2.NumAckPending, cfg.MinInflight)
			continue
		}

		// Confirm poll still shows a parked cohort — fire DELETE immediately.
		log.Printf("ARMED (confirmed): num_ack_pending=%d (was %d) -> DELETE",
			cs2.NumAckPending, cs.NumAckPending)
		if err := connect.DeleteStream(ctx, cfg.StreamID); err != nil {
			return 0, err
		}
		// Return the SECOND poll's count: closest to the DELETE moment and
		// conservative (avoids inflating inflight_at_delete with a transient peak).
		return cs2.NumAckPending, nil
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
