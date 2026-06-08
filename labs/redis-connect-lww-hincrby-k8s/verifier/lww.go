package main

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

// State mirrors the writer's GET /state response. The writer no longer returns
// per-key versions; the authoritative per-key max now lives in srcmax:<epoch> on
// central. /state is used only for the boot_id and epoch-adoption checks.
type State struct {
	BootID string `json:"boot_id"`
	Epoch  string `json:"epoch"`
	Sent   int64  `json:"sent"`
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
	QuiescenceOK      bool    `json:"quiescence_ok"`
	Tombstones        int     `json:"tombstones"`
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
	case !r.QuiescenceOK:
		return LWWVerdict{false, "pipeline did not quiesce before comparison; result is premature (raise the quiescence timeout or lower the rate)"}
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
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(cctx, http.MethodGet, writerURL+"/state", nil)
	resp, err := httpClient.Do(req)
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
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(cctx, http.MethodPost, writerURL+"/reset", stringsReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("/reset status %d", resp.StatusCode)
	}
	return nil
}

// compareSrcMaxMap compares every key in an already-read srcmax map (the
// authoritative HINCRBY-minted max) against region HGET <key> ver. Tombstoned
// keys retain ver==max so they still match. mismatches = region != src;
// regressions = region > src (impossible => fence bug). Taking the snapshot as
// an argument lets the caller read srcmax ONCE and derive every statistic from
// the same map (no divergent re-reads).
func compareSrcMaxMap(ctx context.Context, region *StreamClient, src map[string]int64) (checked, mismatches, regressions int, err error) {
	for key, srcMax := range src {
		cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		regionVer, ok, e := region.HGetVer(cctx, key)
		cancel()
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

// CompareSrcMax reads central's srcmax:<epoch> hash then compares it against the
// region. Convenience wrapper around compareSrcMaxMap for callers (and tests)
// that don't need the snapshot themselves.
func CompareSrcMax(ctx context.Context, central, region *StreamClient, epoch string) (checked, mismatches, regressions int, err error) {
	src, err := central.HGetAllInt(ctx, "srcmax:"+epoch)
	if err != nil {
		return 0, 0, 0, err
	}
	return compareSrcMaxMap(ctx, region, src)
}

// mintEpoch builds a unique epoch token from a caller-supplied seed (the Job
// passes one in; time is not used directly to keep runs reproducible/inspectable).
func mintEpoch(seed string) string {
	if seed == "" {
		return "run"
	}
	return seed
}
