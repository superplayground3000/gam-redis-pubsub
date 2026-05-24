package main

import (
	"context"
	"encoding/json"
	"net/http"
)

type jszConsumer struct {
	NumPending int64 `json:"num_pending"`
}

type jszStream struct {
	Name  string `json:"name"`
	State struct {
		Messages int64 `json:"messages"`
		Bytes    int64 `json:"bytes"`
	} `json:"state"`
	ConsumerDetail []jszConsumer `json:"consumer_detail"`
}

type jszAccountResp struct {
	AccountDetails []struct {
		StreamDetail []jszStream `json:"stream_detail"`
	} `json:"account_details"`
}

type NATSSnap struct {
	Messages   int64
	Bytes      int64
	MaxPending int64
}

func ScrapeJSZ(ctx context.Context, baseURL, streamName string) (NATSSnap, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET",
		baseURL+"/jsz?streams=true&consumers=true&accounts=true", nil)
	resp, err := httpClient.Do(req)
	if err != nil {
		return NATSSnap{}, err
	}
	defer resp.Body.Close()
	var ar jszAccountResp
	if err := json.NewDecoder(resp.Body).Decode(&ar); err != nil {
		return NATSSnap{}, err
	}
	var s NATSSnap
	for _, acc := range ar.AccountDetails {
		for _, st := range acc.StreamDetail {
			if st.Name != streamName {
				continue
			}
			s.Messages = st.State.Messages
			s.Bytes = st.State.Bytes
			for _, c := range st.ConsumerDetail {
				if c.NumPending > s.MaxPending {
					s.MaxPending = c.NumPending
				}
			}
		}
	}
	return s, nil
}
