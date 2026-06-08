package main

import (
	"context"
	"fmt"
	"net"
	"sort"
	"sync"
)

// lwwCounts is one sink pod's cumulative applied/stale/duplicate counters.
type lwwCounts struct{ applied, stale, duplicate int64 }

// SinkBaseline pins the set of sink pod "host:port" endpoints observed at sustain
// start plus their cumulative counters, so end-of-window scrapes can be summed as
// deltas against the SAME pods. A pod vanishing or a counter regressing (restart)
// is a hard precondition failure, not a silent under-count.
type SinkBaseline struct {
	pairs []string // host:port, pinned at baseline
	base  map[string]lwwCounts
}

// dedupeSorted removes adjacent duplicates from an already-sorted slice.
func dedupeSorted(s []string) []string {
	if len(s) < 2 {
		return s
	}
	out := s[:1]
	for _, v := range s[1:] {
		if v != out[len(out)-1] {
			out = append(out, v)
		}
	}
	return out
}

// resolveSinkPairs resolves the headless service DNS name to one host:port per pod.
func resolveSinkPairs(ctx context.Context, dns, port string) ([]string, error) {
	var r net.Resolver
	ips, err := r.LookupHost(ctx, dns)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", dns, err)
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("resolve %s: no sink pod IPs (is connect-sink ready?)", dns)
	}
	sort.Strings(ips)
	ips = dedupeSorted(ips)
	pairs := make([]string, len(ips))
	for i, ip := range ips {
		pairs[i] = net.JoinHostPort(ip, port)
	}
	return pairs, nil
}

// scrapeAllPairs scrapes lww_apply from every host:port concurrently. Any failed
// scrape fails the whole call (the proof needs every pod's counter).
func scrapeAllPairs(ctx context.Context, pairs []string) (map[string]lwwCounts, error) {
	out := make(map[string]lwwCounts, len(pairs))
	var mu sync.Mutex
	var wg sync.WaitGroup
	errs := make([]error, len(pairs))
	for i, hp := range pairs {
		wg.Add(1)
		go func(i int, hp string) {
			defer wg.Done()
			a, s, d, err := ScrapeLWW(ctx, "http://"+hp)
			if err != nil {
				errs[i] = fmt.Errorf("scrape %s: %w", hp, err)
				return
			}
			mu.Lock()
			out[hp] = lwwCounts{a, s, d}
			mu.Unlock()
		}(i, hp)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			return nil, e
		}
	}
	return out, nil
}

// sumDelta returns summed applied/stale/duplicate deltas across pinned pods, failing
// loud if any pod's current counter is below baseline (a restart zeroed cumulative
// counters, which would corrupt the delta and could manufacture a false stale>0).
func sumDelta(pairs []string, base, cur map[string]lwwCounts) (applied, stale, duplicate int64, err error) {
	for _, hp := range pairs {
		c, ok := cur[hp]
		if !ok {
			return 0, 0, 0, fmt.Errorf("sink pod %s missing at end-of-window (rescaled/restarted mid-run): proof invalid", hp)
		}
		z := base[hp]
		if c.applied < z.applied || c.stale < z.stale || c.duplicate < z.duplicate {
			return 0, 0, 0, fmt.Errorf("sink pod %s counter regressed (applied %d->%d, stale %d->%d, dup %d->%d): pod restarted mid-run; proof invalid",
				hp, z.applied, c.applied, z.stale, c.stale, z.duplicate, c.duplicate)
		}
		applied += c.applied - z.applied
		stale += c.stale - z.stale
		duplicate += c.duplicate - z.duplicate
	}
	return applied, stale, duplicate, nil
}

// NewSinkBaseline resolves sink pods and records their baseline counters.
func NewSinkBaseline(ctx context.Context, dns, port string) (*SinkBaseline, error) {
	pairs, err := resolveSinkPairs(ctx, dns, port)
	if err != nil {
		return nil, err
	}
	base, err := scrapeAllPairs(ctx, pairs)
	if err != nil {
		return nil, err
	}
	return &SinkBaseline{pairs: pairs, base: base}, nil
}

// Delta re-scrapes the SAME baseline pods and returns summed deltas.
func (b *SinkBaseline) Delta(ctx context.Context) (applied, stale, duplicate int64, err error) {
	cur, err := scrapeAllPairs(ctx, b.pairs)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("sink delta scrape (a baseline pod went unreachable; rescale/restart breaks the proof): %w", err)
	}
	return sumDelta(b.pairs, b.base, cur)
}

// PodCount reports how many sink pods the baseline pinned (for logging/reporting).
func (b *SinkBaseline) PodCount() int { return len(b.pairs) }
