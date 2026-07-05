package verifier

import (
	"context"
	"encoding/json"
	"fmt"
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
	if baseURL == "" {
		return NATSSnap{}, nil
	}
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
	var (
		s     NATSSnap
		found bool
	)
	for _, acc := range ar.AccountDetails {
		for _, st := range acc.StreamDetail {
			if st.Name != streamName {
				continue
			}
			found = true
			s.Messages = st.State.Messages
			s.Bytes = st.State.Bytes
			for _, c := range st.ConsumerDetail {
				if c.NumPending > s.MaxPending {
					s.MaxPending = c.NumPending
				}
			}
		}
	}
	if !found {
		return s, fmt.Errorf("stream %q not found in /jsz response", streamName)
	}
	return s, nil
}
