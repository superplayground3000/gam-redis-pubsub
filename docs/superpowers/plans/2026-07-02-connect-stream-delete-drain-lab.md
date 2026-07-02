# Connect Stream-Delete Drain Lab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal docker-compose lab that proves `hpdevelop/connect:v4.92.0-batch-nats` never loses messages in JetStream pull-consumer bind mode across stream-close events, and demonstrates that drain-on-close is bounded by `fetch_batch_size`.

**Architecture:** One NATS (JetStream) + one Redis (region target) + a one-shot nats-box (stream+pull-consumer) + one Connect (reverse leg only, streams mode empty-boot) + a Go `harness` (publish/verify/cinfo). A host `smoke-test.sh` POSTs the reverse pipeline, runs preflight validity controls, then four experiments across a `fetch_batch_size` sweep, driving closes via `docker kill`/streams `DELETE`. All design rationale lives in `labs/connect-stream-delete-drain/RESEARCH.md`; empirical build facts in `PROBE-FINDINGS.md`.

**Tech Stack:** docker compose; NATS 2.10 JetStream; Redis 7.4; Redpanda Connect streams mode + Bloblang + redis `eval` (Lua); Go 1.25 harness (`github.com/nats-io/nats.go`, `github.com/redis/go-redis/v9`).

**Key invariants (from RESEARCH.md, do not weaken):**
- One message per key; value = `val:<i>:<event_id>`; identity-verified post-run.
- Apply is a single Lua `EVAL` doing `SET kv_key body` + `INCR applied:kv_key` (atomic).
- Fault gate throws on `meta("nats_num_delivered")=="1"` (first) or always; delivery-count key is `nats_num_delivered` (probe-confirmed).
- Preflight Controls A/B abort loud; experiments trusted only after they pass.
- No loss = every key present carrying its own `event_id`. Redelivery window ≈ `fetch_batch_size` is expected, not failure.

---

## File Structure

```
labs/connect-stream-delete-drain/
├── RESEARCH.md               # exists — design (do not rewrite)
├── PROBE-FINDINGS.md         # exists — empirical facts
├── probe/                    # exists — throwaway probe (keep)
├── docker-compose.yml        # NEW — nats, redis, nats-init, connect, harness, box
├── .env.example              # NEW — all knobs (MSG_COUNT, FETCH_BATCH_SIZES, SLEEP_MS, ACK_WAIT, ARM_INFLIGHT, ports)
├── README.md                 # NEW — what/run/expected/teardown
├── connect/
│   ├── observability.yaml    # NEW — streams boot (http+json logger+metrics)
│   └── reverse.tmpl.yaml      # NEW — POST body template (FETCH_BATCH_SIZE/SLEEP_MS placeholders)
├── harness/
│   ├── go.mod                # NEW
│   ├── main.go               # NEW — subcommand dispatch
│   ├── envelope.go           # NEW — Envelope type, value format, identity check (pure)
│   ├── envelope_test.go      # NEW — unit tests for pure logic
│   ├── commands.go           # NEW — publish/verify/cinfo/wait-inflight (nats+redis)
│   └── Dockerfile            # NEW — multi-stage, distroless runtime
└── scripts/
    └── smoke-test.sh         # NEW — preflight controls + 4 experiments × fetch_batch_size sweep
```

---

## Task 1: Compose stack + Connect configs + .env

**Files:**
- Create: `labs/connect-stream-delete-drain/docker-compose.yml`
- Create: `labs/connect-stream-delete-drain/connect/observability.yaml`
- Create: `labs/connect-stream-delete-drain/connect/reverse.tmpl.yaml`
- Create: `labs/connect-stream-delete-drain/.env.example`

- [ ] **Step 1: Write `connect/observability.yaml`** (copy the proven probe boot config)

```yaml
# Streams-mode bootstrap (connect streams -o ...). JSON logs so smoke-test can
# grep the fault-gate/apply lines; prometheus metrics on /metrics.
http:
  address: 0.0.0.0:4195
  enabled: true
logger:
  level: INFO
  format: json
  add_timestamp: true
metrics:
  prometheus:
    use_histogram_timing: true
```

- [ ] **Step 2: Write `connect/reverse.tmpl.yaml`** (POSTed by smoke-test after envsubst of `__FETCH_BATCH_SIZE__`/`__SLEEP_MS__`)

```yaml
# Reverse leg (POST body). threads:1 for deterministic arming (diverges from the
# chart's threads:4 — recorded in RESEARCH.md). Fault gate keys off the
# probe-confirmed meta key nats_num_delivered. Apply is an atomic Lua EVAL
# (SET + INCR) so the applied counter cannot advance without the write.
input:
  nats_jetstream:
    urls: ["nats://nats:4222"]
    stream: KV_CDC
    durable: cdc_sink
    bind: true
    fetch_batch_size: __FETCH_BATCH_SIZE__
pipeline:
  threads: 1
  processors:
    - sleep:
        duration: __SLEEP_MS__ms
    - switch:
        - check: 'this.fault_mode == "always" || (this.fault_mode == "first" && meta("nats_num_delivered") == "1")'
          processors:
            - log:
                level: INFO
                message: fault-gate
                fields_mapping: |
                  root.event = "fault-gate fired"
                  root.key = this.kv_key
                  root.num_delivered = meta("nats_num_delivered")
            - mapping: 'root = throw("fault-injection %s del=%s".format(this.kv_key, meta("nats_num_delivered")))'
    - log:
        level: INFO
        message: apply
        fields_mapping: |
          root.event = "apply"
          root.key = this.kv_key
          root.num_delivered = meta("nats_num_delivered")
    - redis:
        url: redis://redis:6379
        command: eval
        args_mapping: |
          root = [ "redis.call('SET',KEYS[1],ARGV[1]); return redis.call('INCR','applied:'..KEYS[1])", 1, this.kv_key, this.body ]
output:
  reject_errored:
    drop: {}
```

- [ ] **Step 3: Write `docker-compose.yml`**

```yaml
name: cdc-drain-lab

networks:
  lab: { driver: bridge }

services:
  nats:
    image: nats:2.10-alpine
    command: ["-js", "-sd", "/data", "-m", "8222"]
    ports: ["${NATS_MON_PORT:-18222}:8222"]
    networks: [lab]

  redis:
    image: redis:7.4-alpine
    command: ["redis-server", "--protected-mode", "no", "--save", "", "--appendonly", "no"]
    ports: ["${REDIS_PORT:-16379}:6379"]
    networks: [lab]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 2s
      retries: 30

  nats-init:
    image: natsio/nats-box:0.14.5
    depends_on: [nats]
    networks: [lab]
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        until nats --server nats://nats:4222 rtt >/dev/null 2>&1; do echo waiting nats; sleep 1; done
        nats --server nats://nats:4222 stream add KV_CDC \
          --subjects 'kv.cdc.>' --storage file --replicas 1 --retention limits \
          --discard old --max-age 1h --max-bytes 256MB --max-msgs=-1 \
          --max-msg-size 1MB --dupe-window 2m --defaults
        nats --server nats://nats:4222 consumer add KV_CDC cdc_sink \
          --pull --filter 'kv.cdc.>' --ack explicit --deliver all --replay instant \
          --wait ${ACK_WAIT:-3s} --max-pending 4096 --max-deliver=-1 --defaults
        nats --server nats://nats:4222 consumer info KV_CDC cdc_sink
        echo nats-init done

  box:
    image: natsio/nats-box:0.14.5
    depends_on:
      nats-init: { condition: service_completed_successfully }
    entrypoint: ["sleep", "infinity"]
    networks: [lab]

  connect:
    image: hpdevelop/connect:v4.92.0-batch-nats
    depends_on:
      redis: { condition: service_healthy }
      nats-init: { condition: service_completed_successfully }
    volumes:
      - ./connect/observability.yaml:/etc/connect/observability.yaml:ro
    command: ["streams", "-o", "/etc/connect/observability.yaml"]
    ports: ["${CONNECT_PORT:-14195}:4195"]
    networks: [lab]
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4195/ready"]
      interval: 2s
      timeout: 2s
      retries: 30

  harness:
    build: ./harness
    image: cdc-drain-harness:latest
    depends_on:
      nats-init: { condition: service_completed_successfully }
      redis: { condition: service_healthy }
    entrypoint: ["sleep", "infinity"]   # smoke-test execs subcommands
    environment:
      NATS_URL: nats://nats:4222
      REDIS_ADDR: redis:6379
    networks: [lab]
```

- [ ] **Step 4: Write `.env.example`**

```bash
# Host port mappings (>=15000 to avoid collisions)
CONNECT_PORT=14195
REDIS_PORT=16379
NATS_MON_PORT=18222

# Workload
MSG_COUNT=200          # distinct keys kv:1..kv:N (one message each)
SLEEP_MS=200           # per-msg pipeline sleep = in-flight window
ACK_WAIT=3s            # consumer ack_wait; un-acked redeliver after this
ARM_INFLIGHT=20        # fire close only when num_ack_pending >= this (deterministic arming)
FAULT_EVERY=10         # experiment 0: mark every Nth key fault_mode=first

# The batch knob under test — swept by smoke-test. Comma-separated.
FETCH_BATCH_SIZES=1,16,256
```

- [ ] **Step 5: Validate compose + configs parse**

Run: `cd labs/connect-stream-delete-drain && cp .env.example .env && docker compose config >/dev/null && echo COMPOSE_OK`
Expected: `COMPOSE_OK` (harness build will fail until Task 6 — that's fine; `config` only validates YAML). If `config` complains about the missing build context, temporarily comment the `harness` service or proceed; it is added in Task 6.

- [ ] **Step 6: Commit**

```bash
git add labs/connect-stream-delete-drain/docker-compose.yml labs/connect-stream-delete-drain/connect labs/connect-stream-delete-drain/.env.example
git commit -m "feat(lab): compose stack + reverse pipeline template for stream-delete drain lab"
```

---

## Task 2: Harness module + pure envelope/identity logic (TDD)

**Files:**
- Create: `labs/connect-stream-delete-drain/harness/go.mod`
- Create: `labs/connect-stream-delete-drain/harness/envelope.go`
- Test: `labs/connect-stream-delete-drain/harness/envelope_test.go`

- [ ] **Step 1: Write `go.mod`**

```
module cdc-drain-harness

go 1.25

require (
	github.com/nats-io/nats.go v1.37.0
	github.com/redis/go-redis/v9 v9.19.0
)
```

- [ ] **Step 2: Write the failing test `envelope_test.go`**

```go
package main

import "testing"

func TestValueForKeyEmbedsEventID(t *testing.T) {
	v := valueForKey(5, "eid-abc")
	if v != "val:5:eid-abc" {
		t.Fatalf("got %q", v)
	}
}

func TestParseValueIdentity(t *testing.T) {
	// identity check: value must carry the key's own event_id
	ok := valueMatches("kv:5", "eid-abc", "val:5:eid-abc")
	if !ok {
		t.Fatal("expected identity match")
	}
	if valueMatches("kv:5", "eid-abc", "val:5:OTHER") {
		t.Fatal("wrong event_id must not match")
	}
	if valueMatches("kv:5", "eid-abc", "val:6:eid-abc") {
		t.Fatal("wrong key index must not match")
	}
}

func TestEnvelopeJSONRoundTrip(t *testing.T) {
	e := Envelope{EventID: "e1", Op: "update", KVKey: "kv:1", Body: "val:1:e1", FaultMode: "none"}
	b, err := e.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	got, err := UnmarshalEnvelope(b)
	if err != nil {
		t.Fatal(err)
	}
	if got != e {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd labs/connect-stream-delete-drain/harness && go test ./... 2>&1 | tail -5`
Expected: FAIL — `undefined: valueForKey` etc.

- [ ] **Step 4: Write `envelope.go`**

```go
package main

import (
	"encoding/json"
	"fmt"
)

// Envelope is the self-contained CDC message published to JetStream.
// One message per key; Body embeds the event_id for per-message-instance identity.
type Envelope struct {
	EventID   string `json:"event_id"`
	Op        string `json:"op"`
	KVKey     string `json:"kv_key"`
	Body      string `json:"body"`
	FaultMode string `json:"fault_mode"` // "none" | "first" | "always"
}

func (e Envelope) Marshal() ([]byte, error) { return json.Marshal(e) }

func UnmarshalEnvelope(b []byte) (Envelope, error) {
	var e Envelope
	err := json.Unmarshal(b, &e)
	return e, err
}

// valueForKey is the applied value for key index i: "val:<i>:<event_id>".
func valueForKey(i int, eventID string) string {
	return fmt.Sprintf("val:%d:%s", i, eventID)
}

// valueMatches verifies a region value carries THIS key's own event_id
// (per-message-instance identity). key is like "kv:5".
func valueMatches(key, eventID, got string) bool {
	var idx int
	if _, err := fmt.Sscanf(key, "kv:%d", &idx); err != nil {
		return false
	}
	return got == valueForKey(idx, eventID)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd labs/connect-stream-delete-drain/harness && go test ./... 2>&1 | tail -5`
Expected: `ok  cdc-drain-harness`

- [ ] **Step 6: Commit**

```bash
git add labs/connect-stream-delete-drain/harness/go.mod labs/connect-stream-delete-drain/harness/envelope.go labs/connect-stream-delete-drain/harness/envelope_test.go
git commit -m "feat(lab): harness envelope + identity logic with unit tests"
```

---

## Task 3: Harness commands (publish/verify/cinfo/wait-inflight)

**Files:**
- Create: `labs/connect-stream-delete-drain/harness/commands.go`
- Create: `labs/connect-stream-delete-drain/harness/main.go`

- [ ] **Step 1: Write `commands.go`**

```go
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

// publish writes `count` distinct keys, one message each, recording event_id per
// key in the ledger. faultEvery marks every Nth key fault_mode="first" (0=none).
// Extra single keys can be added with faultMode via the --key/--fault flags.
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
		// single control key: kv:<singleKey-index-agnostic>. Use a negative-safe naming.
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

// verify checks identity completeness + applied counters over keys kv:1..count
// (and any control keys present in the ledger). Prints a report; exits 1 on loss.
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
	redeliveryWindow := appliedSum - n
	fmt.Printf("VERIFY keys=%d missing=%d mismatch=%d applied_sum=%d redelivery_window=%d (keys applied>=2: %d)\n",
		n, missing, mismatch, appliedSum, redeliveryWindow, faultApplied)
	if missing > 0 || mismatch > 0 {
		fmt.Println("RESULT: LOSS/IDENTITY-FAILURE")
		os.Exit(1)
	}
	fmt.Println("RESULT: NO-LOSS")
}

// cinfo prints a consumer field via the JS API (num_ack_pending, num_pending, delivered/ack_floor seq).
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

// waitInflight blocks until num_ack_pending >= target or timeout; prints final value.
func cmdWaitInflight(target int, timeoutS int) {
	nc, js := natsConn()
	defer nc.Close()
	deadline := time.Now().Add(time.Duration(timeoutS) * time.Second)
	var last uint64
	for time.Now().Before(deadline) {
		ci, err := js.ConsumerInfo("KV_CDC", "cdc_sink")
		must(err)
		last = ci.NumAckPending
		if int(last) >= target {
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
```

- [ ] **Step 2: Write `main.go`**

```go
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
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd labs/connect-stream-delete-drain/harness && go build ./... && go vet ./... && echo BUILD_OK`
Expected: `BUILD_OK` (module cache already has nats.go + go-redis; if offline fails, run `go mod tidy` with network).

- [ ] **Step 4: Commit**

```bash
git add labs/connect-stream-delete-drain/harness/commands.go labs/connect-stream-delete-drain/harness/main.go labs/connect-stream-delete-drain/harness/go.sum
git commit -m "feat(lab): harness publish/verify/cinfo/wait-inflight commands"
```

---

## Task 4: Harness Dockerfile + wire into compose

**Files:**
- Create: `labs/connect-stream-delete-drain/harness/Dockerfile`

- [ ] **Step 1: Write `Dockerfile`** (multi-stage, non-root, pinned)

```dockerfile
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download all || true
COPY . .
RUN CGO_ENABLED=0 go build -o /out/harness .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/harness /usr/local/bin/harness
ENTRYPOINT ["/usr/local/bin/harness"]
```

- [ ] **Step 2: Build the image via compose**

Run: `cd labs/connect-stream-delete-drain && docker compose build harness 2>&1 | tail -5 && echo IMG_OK`
Expected: `IMG_OK`. (If `go mod download` needs network and none is available, pre-run `go mod tidy` on host to populate go.sum, then rebuild.)

- [ ] **Step 3: Smoke the whole stack comes up healthy**

Run: `docker compose up -d --wait 2>&1 | tail -5; docker compose ps`
Expected: `nats-init` completed, `redis`/`connect` healthy, `box`/`harness` up.

- [ ] **Step 4: Sanity — harness can reach nats+redis**

Run: `docker compose exec -T harness harness cinfo`
Expected: a line `ack_pending=0 pending=0 delivered=0 ack_floor=0`.

- [ ] **Step 5: Teardown + commit**

```bash
docker compose down -v
git add labs/connect-stream-delete-drain/harness/Dockerfile
git commit -m "feat(lab): harness Dockerfile + compose wiring"
```

---

## Task 5: smoke-test.sh — preflight validity controls

**Files:**
- Create: `labs/connect-stream-delete-drain/scripts/smoke-test.sh`

- [ ] **Step 1: Write the header + helpers + Controls A/B + config gate**

```bash
#!/usr/bin/env bash
# Proves no msg loss in JetStream pull-consumer bind mode across stream close,
# and that drain-on-close is bounded by fetch_batch_size. Preflight Controls
# A/B validate the harness+build BEFORE any experiment is trusted (abort loud).
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
: "${MSG_COUNT:=200}" "${SLEEP_MS:=200}" "${ACK_WAIT:=3s}" "${ARM_INFLIGHT:=20}" "${FAULT_EVERY:=10}" "${FETCH_BATCH_SIZES:=1,16,256}"
API=http://localhost:${CONNECT_PORT:-14195}
ACK_WAIT_S=${ACK_WAIT%s}
line(){ printf '%.0s─' {1..72}; echo; }
fail(){ echo "SMOKE-FAIL: $*"; docker compose logs --tail=50 connect; exit 1; }
h(){ docker compose exec -T harness harness "$@"; }
nats(){ docker compose exec -T box nats --server nats://nats:4222 "$@"; }
reset_consumer(){ nats consumer rm KV_CDC cdc_sink -f >/dev/null 2>&1; nats stream purge KV_CDC -f >/dev/null 2>&1;
  docker compose exec -T box redis-cli -h redis flushall >/dev/null 2>&1 || docker compose exec -T harness sh -c 'true';
  nats consumer add KV_CDC cdc_sink --pull --filter 'kv.cdc.>' --ack explicit --deliver all \
    --replay instant --wait "${ACK_WAIT}" --max-pending 4096 --max-deliver=-1 --defaults >/dev/null 2>&1; }
flush_redis(){ docker compose exec -T box sh -c 'nats --help >/dev/null 2>&1'; docker compose run --rm -T --entrypoint redis-cli harness -h redis flushall >/dev/null 2>&1 || true; }
post_reverse(){ # $1=fetch_batch_size
  sed -e "s/__FETCH_BATCH_SIZE__/$1/" -e "s/__SLEEP_MS__/${SLEEP_MS}/" connect/reverse.tmpl.yaml > /tmp/reverse.yaml
  code=$(curl -sS -o /tmp/post.out -w '%{http_code}' -X POST --data-binary @/tmp/reverse.yaml -H 'Content-Type: application/x-yaml' "$API/streams/reverse")
  [ "$code" = 200 ] || fail "POST reverse -> $code: $(cat /tmp/post.out)"; }
del_reverse(){ curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/streams/reverse"; }
wait_quiescent(){ for _ in $(seq 1 60); do ap=$(h cinfo -field num_ack_pending); np=$(h cinfo -field num_pending);
  [ "${ap:-1}" = 0 ] && [ "${np:-1}" = 0 ] && return 0; sleep 1; done; return 1; }

echo "== bring up stack =="
docker compose up -d --wait 2>&1 | tail -3 || fail "stack did not come up"

line; echo "PREFLIGHT — config gate (secondary)"; line
reset_consumer; post_reverse 4
cfg=$(curl -sS "$API/streams/reverse")
echo "$cfg" | grep -q 'threads: 1' || echo "WARN: GET /streams/reverse may return template, not live graph (Controls A/B are primary)"
del_reverse >/dev/null; sleep 1

line; echo "PREFLIGHT — Control A (throw ⇒ nack, not drop-and-ack)"; line
reset_consumer
docker compose run --rm -T --entrypoint redis-cli harness -h redis flushall >/dev/null 2>&1 || true
post_reverse 4
# ctrlA: single always-faulting key (kv:9001). It hot-loops (immediate nack redelivery).
h publish -key 9001 -fault always
d0=$(h cinfo -field delivered); sleep "$ACK_WAIT_S"; sleep 1; d1=$(h cinfo -field delivered)
present=$(docker compose run --rm -T --entrypoint redis-cli harness -h redis exists kv:9001 2>/dev/null | tr -d '\r')
echo "ctrlA: delivered ${d0}→${d1}, kv:9001 exists=${present}"
[ "${d1:-0}" -gt "${d0:-0}" ] 2>/dev/null || fail "Control A: ctrlA did not redeliver ⇒ throw is drop-and-ack ⇒ experiment 0 invalid"
[ "${present}" = 0 ] || fail "Control A: faulting ctrlA got applied while failing ⇒ gate/throw broken"
del_reverse >/dev/null; sleep 1   # stop the hot loop

line; echo "PREFLIGHT — Control B (gate fires del=1, applies on del=2)"; line
reset_consumer
docker compose run --rm -T --entrypoint redis-cli harness -h redis flushall >/dev/null 2>&1 || true
post_reverse 4
h publish -key 9002 -fault first
sleep 3
gate1=$(docker compose logs connect 2>/dev/null | grep -c '"event":"fault-gate fired".*"key":"kv:9002".*"num_delivered":"1"')
apply2=$(docker compose logs connect 2>/dev/null | grep -c '"event":"apply".*"key":"kv:9002".*"num_delivered":"2"')
applied=$(docker compose run --rm -T --entrypoint redis-cli harness -h redis get applied:kv:9002 2>/dev/null | tr -d '\r')
echo "ctrlB: gate(del=1)=${gate1} apply(del=2)=${apply2} applied:kv:9002=${applied}"
[ "${gate1:-0}" -ge 1 ] 2>/dev/null || fail "Control B: fault-gate did not fire on delivery 1 (meta key wrong?)"
[ "${apply2:-0}" -ge 1 ] 2>/dev/null || fail "Control B: no apply on a distinct delivery 2 (within-delivery retry?)"
[ "${applied:-0}" = 2 ] 2>/dev/null || fail "Control B: applied:kv:9002=${applied}, expected 2"
del_reverse >/dev/null; sleep 1
echo "PREFLIGHT PASSED — controls validate the build+harness"
```

- [ ] **Step 2: Make executable + syntax check**

Run: `chmod +x labs/connect-stream-delete-drain/scripts/smoke-test.sh && bash -n labs/connect-stream-delete-drain/scripts/smoke-test.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 3: Run preflight only** (temporarily add `exit 0` after preflight, or run whole once Task 6 appends experiments)

Run: `cd labs/connect-stream-delete-drain && bash scripts/smoke-test.sh 2>&1 | sed -n '1,40p'`
Expected: `PREFLIGHT PASSED`. If Control A/B abort, read the connect logs — the build's semantics differ from the probe and the design must be revisited before trusting experiments.

- [ ] **Step 4: Commit**

```bash
git add labs/connect-stream-delete-drain/scripts/smoke-test.sh
git commit -m "feat(lab): smoke-test preflight validity controls (A/B + config gate)"
```

---

## Task 6: smoke-test.sh — four experiments × fetch_batch_size sweep

**Files:**
- Modify: `labs/connect-stream-delete-drain/scripts/smoke-test.sh` (append experiments before final teardown)

- [ ] **Step 1: Append the experiment loop**

```bash

line; echo "EXPERIMENTS — sweep FETCH_BATCH_SIZES=${FETCH_BATCH_SIZES}"; line
IFS=',' read -ra FBS <<< "${FETCH_BATCH_SIZES}"
overall=0
flush(){ docker compose run --rm -T --entrypoint redis-cli harness -h redis flushall >/dev/null 2>&1 || true; }
restart_connect(){ docker compose up -d connect --wait >/dev/null 2>&1; }

for fb in "${FBS[@]}"; do
  line; echo "### fetch_batch_size=${fb}"; line

  # Experiment 0 — apply-fault injection (no close)
  reset_consumer; flush; post_reverse "$fb"
  h publish -count "${MSG_COUNT}" -fault-every "${FAULT_EVERY}"
  wait_quiescent || fail "exp0 fb=$fb: not quiescent"
  h verify -count "${MSG_COUNT}" || { overall=1; echo "EXP0 fb=$fb FAIL"; }
  del_reverse >/dev/null; sleep 1

  # Experiment 1 — Streams DELETE, then re-bind for redelivery recovery
  reset_consumer; flush; post_reverse "$fb"
  h publish -count "${MSG_COUNT}"
  inflight=$(h wait-inflight -target "${ARM_INFLIGHT}" -timeout 20)
  echo "exp1 fb=$fb: armed at num_ack_pending=${inflight}"
  [ "${inflight:-0}" -ge "${ARM_INFLIGHT}" ] 2>/dev/null || echo "  NOTE: fb=$fb cannot reach ARM_INFLIGHT=${ARM_INFLIGHT} (small batch) — close window is inherently tiny"
  t0=$(date +%s.%N); code=$(del_reverse); t1=$(date +%s.%N)
  echo "  DELETE -> $code in $(awk "BEGIN{printf \"%.2f\", $t1-$t0}")s"
  abandoned=$(h cinfo -field num_ack_pending); echo "  abandoned un-acked after DELETE: ${abandoned}"
  post_reverse "$fb"                       # re-bind ⇒ redelivery drains
  wait_quiescent || fail "exp1 fb=$fb: not quiescent after re-bind"
  h verify -count "${MSG_COUNT}" || { overall=1; echo "EXP1 fb=$fb FAIL (LOSS)"; }
  del_reverse >/dev/null; sleep 1

  # Experiment 2 — SIGTERM, restart, re-bind
  reset_consumer; flush; post_reverse "$fb"
  h publish -count "${MSG_COUNT}"
  h wait-inflight -target "${ARM_INFLIGHT}" -timeout 20 >/dev/null
  docker compose kill -s SIGTERM connect >/dev/null 2>&1
  restart_connect; post_reverse "$fb"
  wait_quiescent || fail "exp2 fb=$fb: not quiescent after SIGTERM+restart"
  h verify -count "${MSG_COUNT}" || { overall=1; echo "EXP2 fb=$fb FAIL (LOSS)"; }
  del_reverse >/dev/null; sleep 1

  # Experiment 3 — SIGKILL, restart, re-bind (safety floor)
  reset_consumer; flush; post_reverse "$fb"
  h publish -count "${MSG_COUNT}"
  h wait-inflight -target "${ARM_INFLIGHT}" -timeout 20 >/dev/null
  docker compose kill -s SIGKILL connect >/dev/null 2>&1
  restart_connect; post_reverse "$fb"
  wait_quiescent || fail "exp3 fb=$fb: not quiescent after SIGKILL+restart"
  h verify -count "${MSG_COUNT}" || { overall=1; echo "EXP3 fb=$fb FAIL (LOSS)"; }
  del_reverse >/dev/null; sleep 1
done

line
if [ "$overall" = 0 ]; then
  echo "SMOKE-PASS: no message loss across DELETE/SIGTERM/SIGKILL for all fetch_batch_size in {${FETCH_BATCH_SIZES}}."
  echo "  (Redelivery window scales with fetch_batch_size; fb=1 is drain-clean. See per-experiment output above.)"
else
  echo "SMOKE-FAIL: at least one experiment lost messages or failed identity — see EXP*/FAIL lines above."
fi
[ "${KEEP:-0}" = 1 ] || { echo "== teardown =="; docker compose down -v 2>&1 | tail -2; }
exit "$overall"
```

- [ ] **Step 2: Syntax check**

Run: `bash -n labs/connect-stream-delete-drain/scripts/smoke-test.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 3: Full run (the property test)**

Run: `cd labs/connect-stream-delete-drain && timeout 900 bash scripts/smoke-test.sh 2>&1 | tail -40`
Expected: `SMOKE-PASS: no message loss ...`. Every EXP0..3 for every fb prints `RESULT: NO-LOSS`. Exp1 shows `abandoned` ≈ min(inflight, fetch_batch_size) and a redelivery_window that grows with fb (≈0 at fb=1).

- [ ] **Step 4: Debug loop if needed**

If an experiment reports LOSS: `docker compose logs connect | grep -E 'apply|fault-gate' | tail`, check `h verify` MISSING/IDENTITY lines, and confirm `reset_consumer` flushed Redis + purged the stream between experiments. Do NOT weaken the oracle to pass.

- [ ] **Step 5: Commit**

```bash
git add labs/connect-stream-delete-drain/scripts/smoke-test.sh
git commit -m "feat(lab): smoke-test experiments 0-3 across fetch_batch_size sweep"
```

---

## Task 7: README + final validation + cleanup

**Files:**
- Create: `labs/connect-stream-delete-drain/README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# connect-stream-delete-drain

## What this demonstrates

`hpdevelop/connect:v4.92.0-batch-nats` in JetStream pull-consumer bind mode loses no
messages across stream close (Streams `DELETE`, `SIGTERM`, `SIGKILL`); drain-on-close
is bounded by `fetch_batch_size` (fb=1 is drain-clean, larger fb replays more on close).

## Run it

```bash
cp .env.example .env
bash scripts/smoke-test.sh          # KEEP=1 to leave the stack up
```

## Expected output

`SMOKE-PASS: no message loss across DELETE/SIGTERM/SIGKILL for all fetch_batch_size ...`
with every experiment printing `RESULT: NO-LOSS`, and Exp1's `redelivery_window` growing
with `fetch_batch_size` (≈0 at fb=1).

## Teardown

```bash
docker compose down -v
```

## Further reading

- `RESEARCH.md` — design + the seven-round review that shaped the oracle.
- `PROBE-FINDINGS.md` — measured build behavior (why DELETE/SIGTERM don't drain).
```

- [ ] **Step 2: Run the skill's validator**

Run: `bash /home/hp/.claude/skills/research-lab/scripts/validate_lab.sh labs/connect-stream-delete-drain 2>&1 | tail -20`
Expected: exit 0. If it flags missing healthchecks or `:latest`, fix in compose (nats has no healthcheck by design — it is gated by nats-init; add a one-line comment if the validator requires justification).

- [ ] **Step 3: Confirm clean teardown**

Run: `docker ps -a --filter name=cdc-drain-lab --format '{{.Names}}'; docker volume ls | grep cdc-drain || echo NO_VOLUMES`
Expected: no containers, `NO_VOLUMES`.

- [ ] **Step 4: Commit**

```bash
git add labs/connect-stream-delete-drain/README.md
git commit -m "docs(lab): README + validated connect-stream-delete-drain lab"
```

---

## Self-Review notes (spec coverage)

- One-message-per-key + identity: `envelope.go` `valueForKey`/`valueMatches`, ledger in `cmdPublish`/`cmdVerify` (Tasks 2–3). ✓
- Atomic SET+INCR Lua: `reverse.tmpl.yaml` redis `eval` (Task 1). ✓
- Fault gate on `nats_num_delivered`, always/first modes: `reverse.tmpl.yaml` switch (Task 1); driven by `-fault` flag (Task 3). ✓
- Preflight Control A (throw⇒nack), Control B (gate del=1 / apply del=2 / applied==2), config gate: Task 5. ✓
- Deterministic arming (`ARM_INFLIGHT`, `wait-inflight`): Tasks 3, 6. ✓
- Experiments 0 (fault), 1 (DELETE+rebind), 2 (SIGTERM), 3 (SIGKILL) across fetch_batch_size sweep; identity-N oracle; redelivery-window reporting: Task 6. ✓
- No-loss verdict via identity, not counters; redelivery expected not failed: `cmdVerify` + Task 6 messaging. ✓
- Ports ≥15000, healthchecks, pinned tags, service-name networking: Task 1. ✓
```
