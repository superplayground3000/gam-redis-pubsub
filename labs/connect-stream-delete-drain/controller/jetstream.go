package main

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	streamName   = "CDC"
	subject      = "cdc.kv"
	consumerName = "sink"
)

type jsClient struct {
	nc  *nats.Conn
	js  jetstream.JetStream
	con jetstream.Consumer
}

func dialJetStream(ctx context.Context, url string) (*jsClient, error) {
	nc, err := nats.Connect(url, nats.Timeout(5*time.Second), nats.MaxReconnects(-1))
	if err != nil {
		return nil, err
	}
	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, err
	}
	return &jsClient{nc: nc, js: js}, nil
}

// setup deletes any prior stream (clean epoch) then creates the stream and a
// durable pull consumer bound to a small ack_wait so un-acked msgs redeliver fast.
func (c *jsClient) setup(ctx context.Context, ackWait time.Duration, maxAckPending int) error {
	if err := c.js.DeleteStream(ctx, streamName); err != nil && !errors.Is(err, jetstream.ErrStreamNotFound) {
		return fmt.Errorf("clean prior stream: %w", err)
	}
	st, err := c.js.CreateStream(ctx, jetstream.StreamConfig{
		Name:     streamName,
		Subjects: []string{subject},
		Storage:  jetstream.FileStorage,
	})
	if err != nil {
		return fmt.Errorf("create stream: %w", err)
	}
	con, err := st.CreateOrUpdateConsumer(ctx, jetstream.ConsumerConfig{
		Durable:       consumerName,
		FilterSubject: subject,
		AckPolicy:     jetstream.AckExplicitPolicy,
		AckWait:       ackWait,
		MaxAckPending: maxAckPending,
	})
	if err != nil {
		return fmt.Errorf("create consumer: %w", err)
	}
	c.con = con
	return nil
}

// publish emits n messages {"i":k} with header Nats-Msg-Id=k for dedup, at rate
// msgs/s (0 = burst).
func (c *jsClient) publish(ctx context.Context, n, rate int) error {
	var tick <-chan time.Time
	if rate > 0 {
		t := time.NewTicker(time.Second / time.Duration(rate))
		defer t.Stop()
		tick = t.C
	}
	for k := 1; k <= n; k++ {
		if tick != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-tick:
			}
		}
		body := []byte(fmt.Sprintf(`{"i":%d}`, k))
		if _, err := c.js.Publish(ctx, subject, body, jetstream.WithMsgID(strconv.Itoa(k))); err != nil {
			return fmt.Errorf("publish %d: %w", k, err)
		}
	}
	return nil
}

func (c *jsClient) consumerState(ctx context.Context) (ConsumerState, error) {
	info, err := c.con.Info(ctx)
	if err != nil {
		return ConsumerState{}, err
	}
	return ConsumerState{NumPending: info.NumPending, NumAckPending: info.NumAckPending}, nil
}

func (c *jsClient) close() { c.nc.Close() }
