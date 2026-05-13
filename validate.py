"""
Convergence + parity validator.

Two checks:
  1. DBSIZE on every edge must reach --count within --timeout seconds.
     This proves the relay finished applying every event.
  2. For a random sample of keys, all edges must hold an identical value.
     This proves edges are byte-for-byte consistent (no ordering bugs).
"""

import argparse
import os
import random
import sys
import time
import redis


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--count",   type=int, required=True,
                   help="expected number of keys on each edge")
    p.add_argument("--edges",   nargs="+",
                   default=os.environ.get("EDGE_URLS",
                       "redis://localhost:6381,redis://localhost:6382,redis://localhost:6383"
                   ).split(","),
                   help="edge Redis URLs")
    p.add_argument("--timeout", type=int, default=600,
                   help="max seconds to wait for convergence")
    p.add_argument("--sample",  type=int, default=1000,
                   help="number of keys to spot-check for value parity")
    p.add_argument("--prefix",  default="k:")
    p.add_argument("--poll",    type=float, default=1.0,
                   help="seconds between dbsize polls")
    return p.parse_args()


def fmt(n: int) -> str:
    return f"{n:,}"


def wait_for_convergence(edges, expected: int, timeout: int, poll: float) -> bool:
    """Block until every edge's DBSIZE >= expected, or timeout."""
    print(f"\n[1/2] waiting for convergence to {fmt(expected)} keys on {len(edges)} edges "
          f"(timeout {timeout}s)...")
    deadline = time.time() + timeout
    last_total = -1
    last_change_at = time.time()

    while time.time() < deadline:
        sizes = [(url, c.dbsize()) for url, c in edges]
        total = sum(s for _, s in sizes)
        line  = "  " + " | ".join(f"{url.split('//')[-1]}={fmt(s)}" for url, s in sizes)
        sys.stdout.write("\r" + line.ljust(110))
        sys.stdout.flush()

        if all(s >= expected for _, s in sizes):
            print(f"\n  CONVERGED in ~{int(deadline - time.time())}s remaining slack")
            return True

        if total != last_total:
            last_total = total
            last_change_at = time.time()
        elif time.time() - last_change_at > 30:
            # No progress for 30s — likely stuck. Continue but warn.
            print("\n  WARN: no DBSIZE change for 30s; relay may be stalled.")
            last_change_at = time.time()  # reset to avoid spam

        time.sleep(poll)

    print("\n  TIMEOUT")
    return False


def check_value_parity(edges, expected: int, sample: int, prefix: str) -> int:
    """Verify random sample of keys has identical value on every edge."""
    print(f"\n[2/2] checking value parity on {fmt(sample)} random keys...")
    indices = random.sample(range(expected), min(sample, expected))
    mismatches = []

    for idx in indices:
        key  = f"{prefix}{idx}"
        vals = [c.get(key) for _, c in edges]
        if any(v is None for v in vals) or len(set(vals)) != 1:
            mismatches.append((key, vals))

    if mismatches:
        print(f"  FAIL: {fmt(len(mismatches))}/{fmt(sample)} keys had divergent or missing values")
        for key, vals in mismatches[:5]:
            print(f"    {key} -> {vals}")
        return len(mismatches)

    print(f"  PASS: all {fmt(sample)} sampled keys match across {len(edges)} edges")
    return 0


def main():
    args  = parse_args()
    edges = [(u, redis.from_url(u, decode_responses=True)) for u in args.edges]

    print(f"=== validator ===")
    print(f"  edges  : {[u for u, _ in edges]}")
    print(f"  expect : {fmt(args.count)} keys")

    start = time.time()
    if not wait_for_convergence([(u, c) for u, c in edges], args.count, args.timeout, args.poll):
        sys.exit(2)

    mismatches = check_value_parity([(u, c) for u, c in edges], args.count, args.sample, args.prefix)
    elapsed = time.time() - start

    print(f"\nELAPSED: {elapsed:.1f}s")
    if mismatches:
        sys.exit(1)
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
