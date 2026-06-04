package main

import (
	"context"
	"fmt"
	"net/http"
)

// State mirrors the writer's GET /state response.
type State struct {
	BootID        string           `json:"boot_id"`
	Epoch         string           `json:"epoch"`
	Keys          map[string]int64 `json:"keys"`
	DistinctKeys  int              `json:"distinct_keys"`
	TotalVersions int64            `json:"total_versions"`
}

// LWWResult is the per-run measurement + verdict input.
type LWWResult struct {
	Epoch             string  `json:"epoch"`
	KeysChecked       int     `json:"keys_checked"`
	Mismatches        int     `json:"mismatches"`
	Regressions       int     `json:"regressions"`
	Applied           int64   `json:"applied"`
	Stale             int64   `json:"stale"`
	Duplicate         int64   `json:"duplicate"`
	WritesPerKeyAvg   float64 `json:"writes_per_key_avg"`
	RateTarget        int     `json:"rate_target"`
	RateAchievedAvg   float64 `json:"rate_achieved_avg"`
	BootOK            bool    `json:"boot_ok"`
	StoreEmptyAtStart bool    `json:"store_empty_at_start"`
}

type LWWVerdict struct {
	Pass   bool   `json:"pass"`
	Reason string `json:"reason,omitempty"`
}

// ComputeLWWVerdict encodes spec §3.4: pass requires the precondition to hold,
// final state correct, throughput measured, AND a windowed strictly-older (stale)
// arrival observed (proof reordering was exercised and fenced).
func ComputeLWWVerdict(r LWWResult) LWWVerdict {
	switch {
	case !r.StoreEmptyAtStart:
		return LWWVerdict{false, "precondition violated: region not empty for run epoch at start"}
	case !r.BootOK:
		return LWWVerdict{false, "precondition violated: writer restarted mid-run (boot_id changed)"}
	case r.Regressions > 0:
		return LWWVerdict{false, fmt.Sprintf("IMPOSSIBLE: %d keys have region_ver > source_ver (fence bug)", r.Regressions)}
	case r.Mismatches > 0:
		return LWWVerdict{false, fmt.Sprintf("%d keys: region_ver != source_max (stale write won or message lost)", r.Mismatches)}
	case r.RateAchievedAvg <= 0:
		return LWWVerdict{false, "no throughput measured"}
	case r.Stale == 0:
		return LWWVerdict{false, "inconclusive — no strictly-older arrival observed in the measured window; reorder-fencing unproven end-to-end"}
	default:
		return LWWVerdict{true, ""}
	}
}

// FetchState GETs the writer /state.
func FetchState(ctx context.Context, writerURL string) (State, error) {
	var st State
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, writerURL+"/state", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return st, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return st, fmt.Errorf("/state status %d", resp.StatusCode)
	}
	return st, decodeJSON(resp, &st)
}

// PostResetEpoch POSTs /reset {"epoch":...}.
func PostResetEpoch(ctx context.Context, writerURL, epoch string) error {
	body := fmt.Sprintf(`{"epoch":%q}`, epoch)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, writerURL+"/reset", stringsReader(body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("/reset status %d", resp.StatusCode)
	}
	return nil
}

// CompareVersions reads region HGET <key> ver for every key in state and tallies
// mismatches (region != source max) and regressions (region > source max).
func CompareVersions(ctx context.Context, region *StreamClient, st State) (checked, mismatches, regressions int, err error) {
	for key, srcMax := range st.Keys {
		regionVer, ok, e := region.HGetVer(ctx, key)
		if e != nil {
			return checked, mismatches, regressions, e
		}
		checked++
		if !ok || regionVer != srcMax {
			mismatches++
		}
		if ok && regionVer > srcMax {
			regressions++
		}
	}
	return checked, mismatches, regressions, nil
}

// StoreEmptyForEpoch samples up to n of the epoch's candidate keys and returns
// true iff none already has a stored version (the §3.4.1 empty-store guard).
// Called BEFORE traffic; state.Keys is empty then, so it probes the deterministic
// candidate keys lww:<epoch>:0..n-1.
func StoreEmptyForEpoch(ctx context.Context, region *StreamClient, epoch string, n int) (bool, error) {
	for i := 0; i < n; i++ {
		key := fmt.Sprintf("lww:%s:%d", epoch, i)
		if _, ok, err := region.HGetVer(ctx, key); err != nil {
			return false, err
		} else if ok {
			return false, nil
		}
	}
	return true, nil
}

// mintEpoch builds a unique epoch token from a caller-supplied seed (the Job
// passes one in; time is not used directly to keep runs reproducible/inspectable).
func mintEpoch(seed string) string {
	if seed == "" {
		return "run"
	}
	return seed
}
