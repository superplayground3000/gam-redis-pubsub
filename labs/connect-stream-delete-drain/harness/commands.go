package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/redis/go-redis/v9"
)

func natsConn() (*nats.Conn, nats.JetStreamContext) {
	url := envOr("NATS_URL", "nats://nats:4222")
	nc, err := nats.Connect(url, nats.Timeout(5*time.Second))
	must(err)
	js, err := nc.JetStream()
	must(err)
	return nc, js
}

func rdb() *redis.Client {
	return redis.NewClient(&redis.Options{Addr: envOr("REDIS_ADDR", "redis:6379")})
}

func newEventID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// keyIndex→eventID ledger persisted in Redis so verify (a separate invocation)
// can check identity. Stored under hash "ledger".
const ledgerKey = "ledger"

// cmdPublish writes `count` distinct keys, one message each, recording event_id
// per key in the ledger. faultEvery marks every Nth key fault_mode="first"
// (0=none). A single control key can be published with singleKey/singleFault.
func cmdPublish(count, faultEvery int, singleKey, singleFault string) {
	nc, js := natsConn()
	defer nc.Close()
	r := rdb()
	ctx := context.Background()

	pubOne := func(idx int, faultMode string) {
		eid := newEventID()
		e := Envelope{EventID: eid, Op: "update", KVKey: fmt.Sprintf("kv:%d", idx),
			Body: valueForKey(idx, eid), FaultMode: faultMode}
		b, err := e.Marshal()
		must(err)
		_, err = js.Publish("kv.cdc.update", b, nats.MsgId(eid))
		must(err)
		must(r.HSet(ctx, ledgerKey, e.KVKey, eid).Err())
	}

	if singleKey != "" {
		idx, _ := strconv.Atoi(singleKey)
		pubOne(idx, singleFault)
		fmt.Printf("published control kv:%d fault_mode=%s\n", idx, singleFault)
		return
	}
	for i := 1; i <= count; i++ {
		fm := "none"
		if faultEvery > 0 && i%faultEvery == 0 {
			fm = "first"
		}
		pubOne(i, fm)
	}
	fmt.Printf("published %d keys (fault every %d)\n", count, faultEvery)
}

// cmdVerify checks identity completeness + applied counters over every key in
// the ledger. Prints a report; exits 1 on any loss or identity mismatch.
func cmdVerify(count int) {
	r := rdb()
	ctx := context.Background()
	ledger := r.HGetAll(ctx, ledgerKey).Val()

	missing, mismatch, appliedSum, faultApplied := 0, 0, 0, 0
	for key, eid := range ledger {
		got, err := r.Get(ctx, key).Result()
		if err == redis.Nil {
			missing++
			fmt.Printf("MISSING %s\n", key)
			continue
		}
		must(err)
		if !valueMatches(key, eid, got) {
			mismatch++
			fmt.Printf("IDENTITY-MISMATCH %s got=%q want eid=%s\n", key, got, eid)
		}
		ac, _ := r.Get(ctx, "applied:"+key).Int()
		appliedSum += ac
		if ac >= 2 {
			faultApplied++
		}
	}
	n := len(ledger)
	doubleApplied := appliedSum - n // messages applied >once (apply-then-close-before-ack); usually ~0
	fmt.Printf("VERIFY keys=%d missing=%d mismatch=%d applied_sum=%d double_applied=%d (keys applied>=2: %d)\n",
		n, missing, mismatch, appliedSum, doubleApplied, faultApplied)
	if missing > 0 || mismatch > 0 {
		fmt.Println("RESULT: LOSS/IDENTITY-FAILURE")
		os.Exit(1)
	}
	fmt.Println("RESULT: NO-LOSS")
}

// cmdCinfo prints a consumer field (or a summary line) via the JS API.
func cmdCinfo(field string) {
	nc, js := natsConn()
	defer nc.Close()
	ci, err := js.ConsumerInfo("KV_CDC", "cdc_sink")
	must(err)
	switch field {
	case "num_ack_pending":
		fmt.Println(ci.NumAckPending)
	case "num_pending":
		fmt.Println(ci.NumPending)
	case "delivered":
		fmt.Println(ci.Delivered.Consumer)
	case "ack_floor":
		fmt.Println(ci.AckFloor.Consumer)
	default:
		fmt.Printf("ack_pending=%d pending=%d delivered=%d ack_floor=%d\n",
			ci.NumAckPending, ci.NumPending, ci.Delivered.Consumer, ci.AckFloor.Consumer)
	}
}

// cmdWaitInflight blocks until num_ack_pending >= target or timeout; prints final value.
func cmdWaitInflight(target int, timeoutS int) {
	nc, js := natsConn()
	defer nc.Close()
	deadline := time.Now().Add(time.Duration(timeoutS) * time.Second)
	var last int
	for time.Now().Before(deadline) {
		ci, err := js.ConsumerInfo("KV_CDC", "cdc_sink")
		must(err)
		last = ci.NumAckPending
		if last >= target {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	fmt.Println(last)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(2)
	}
}
