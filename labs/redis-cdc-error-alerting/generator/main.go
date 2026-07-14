// generator publishes CDC envelopes to NATS JetStream subject kv.cdc.<op>.
// MODE=healthy|poison|hashpoison|mixed, RATE msgs/sec, DURATION seconds (0 = forever),
// COUNT exact number of messages then exit (0 = use DURATION instead).
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strconv"
	"time"

	"github.com/nats-io/nats.go"
)

type envelope struct {
	EventID string `json:"event_id"`
	Op      string `json:"op"`
	Type    string `json:"type"`
	KVKey   string `json:"kv_key"`
	OldKey  string `json:"old_key"`
	NewKey  string `json:"new_key"`
	TS      string `json:"ts"`
	Enc     string `json:"enc,omitempty"`
	Body    string `json:"body,omitempty"`
}

func gzipB64(b []byte) string {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	_, _ = w.Write(b)
	_ = w.Close()
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	mode := env("MODE", "mixed")
	rate, _ := strconv.Atoi(env("RATE", "20"))
	dur, _ := strconv.Atoi(env("DURATION", "0"))
	// COUNT (>0) publishes EXACTLY that many messages then exits — an exact, not
	// approximate (rate*duration), batch size. The DLQ phase relies on this for its
	// no-loss (INV-1) assertion: injected N must equal N dead-lettered + N acked.
	count, _ := strconv.Atoi(env("COUNT", "0"))
	url := env("NATS_URL", "nats://nats:4222")

	nc, err := nats.Connect(url, nats.Timeout(5*time.Second), nats.RetryOnFailedConnect(true), nats.MaxReconnects(-1))
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	js, err := nc.JetStream()
	if err != nil {
		log.Fatalf("jetstream: %v", err)
	}

	if rate < 1 {
		rate = 1
	}
	tick := time.NewTicker(time.Second / time.Duration(rate))
	defer tick.Stop()
	deadline := time.Time{}
	if dur > 0 {
		deadline = time.Now().Add(time.Duration(dur) * time.Second)
	}
	log.Printf("generator mode=%s rate=%d/s duration=%ds count=%d", mode, rate, dur, count)

	n := 0         // messages attempted
	published := 0 // messages the broker accepted (PublishMsg returned no error)
	for range tick.C {
		if count > 0 && n >= count {
			log.Printf("generator done after %d msgs (published=%d, exact count=%d)", n, published, count)
			if published != count {
				log.Fatalf("FATAL: published %d != requested count %d — batch not exact", published, count)
			}
			return
		}
		if !deadline.IsZero() && time.Now().After(deadline) {
			log.Printf("generator done after %d msgs", n)
			return
		}
		e := next(mode, n)
		payload, _ := json.Marshal(e)
		subj := "kv.cdc." + e.Op
		msg := &nats.Msg{Subject: subj, Data: payload, Header: nats.Header{"Nats-Msg-Id": []string{e.EventID}}}
		if _, err := js.PublishMsg(msg); err != nil {
			log.Printf("publish %s: %v", subj, err)
		} else {
			published++
		}
		n++
	}
}

// next builds the nth envelope for the given mode.
func next(mode string, n int) envelope {
	switch mode {
	case "healthy":
		return healthy(n)
	case "poison":
		return poison(n)
	case "hashpoison":
		return hashpoison(n)
	default: // mixed: ~1 in 10 is poison
		if n%10 == 0 {
			return poison(n)
		}
		return healthy(n)
	}
}

func healthy(n int) envelope {
	key := fmt.Sprintf("k%d", n%50) // small keyspace so update/delete hit existing keys
	base := envelope{EventID: fmt.Sprintf("h-%d", n), Type: "string", KVKey: key, TS: strconv.FormatInt(time.Now().UnixMilli(), 10)}
	switch n % 3 {
	case 0:
		base.Op = "create"
		base.Enc = "gzip:base64"
		base.Body = gzipB64([]byte(fmt.Sprintf(`{"v":%d}`, n)))
	case 1:
		base.Op = "update"
		base.Enc = "gzip:base64"
		base.Body = gzipB64([]byte(fmt.Sprintf(`{"v":%d,"u":1}`, n)))
	default:
		base.Op = "delete"
	}
	return base
}

func poison(n int) envelope {
	base := envelope{EventID: fmt.Sprintf("p-%d", n), Type: "string", KVKey: fmt.Sprintf("poison%d", n), TS: strconv.FormatInt(time.Now().UnixMilli(), 10)}
	if rand.Intn(2) == 0 {
		// unknown_op: op outside create/update/delete/rename
		base.Op = "frobnicate"
	} else {
		// decode_error: create/update claiming gzip:base64 but body is not valid base64/gzip
		base.Op = "create"
		base.Enc = "gzip:base64"
		base.Body = "!!!this-is-not-base64-gzip!!!"
	}
	return base
}

// hashpoison builds a create/type=hash envelope whose body is well-formed JSON
// but NOT a JSON object (a JSON array) — the HSET args_mapping downstream does
// parse_json().key_values(), which is only valid on an object, so this fails the
// sink's hash-guard (parse_json().type() != "object") and dead-letters to
// dlq.cdc.hash_decode_error instead of throwing uncounted inside HSET.
//
// NOTE: an earlier version used a trailing-comma body ({"a":"1","b":"2",}) as the
// "malformed" poison, but this Connect runtime's parse_json TOLERATES a trailing
// comma (it yields a plain string rather than an error), so .type()=="object"
// still passed and the body was NOT dead-lettered. A JSON array is a reliable
// non-object that the guard classifies deterministically (it is also one of the
// chart's own cited examples: `["a","b"]`). event_id is time+index unique so
// repeated hashpoison runs are not swallowed by the stream's dedupe window.
func hashpoison(n int) envelope {
	return envelope{
		EventID: fmt.Sprintf("hp-%d-%d", time.Now().UnixNano(), n),
		Op:      "create",
		Type:    "hash",
		KVKey:   fmt.Sprintf("hp:%d", n),
		TS:      strconv.FormatInt(time.Now().UnixMilli(), 10),
		Body:    `["a","b"]`,
	}
}
