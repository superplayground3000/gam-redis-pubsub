"""
Pipelined event producer.

Pushes N synthetic events into the central Redis Stream using a pipeline so
publishing throughput isn't the bottleneck. Tune --batch to match available
memory.
"""

import argparse
import os
import time
import redis


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--count",  type=int, default=10_000, help="number of events")
    p.add_argument("--batch",  type=int, default=1000,   help="pipeline depth")
    p.add_argument("--url",    default=os.environ.get("CENTRAL_URL", "redis://localhost:6379"))
    p.add_argument("--stream", default=os.environ.get("STREAM_KEY", "events"))
    p.add_argument("--prefix", default="k:",     help="key prefix on edges")
    p.add_argument("--trim",   type=int, default=0,
                   help="MAXLEN ~ N to cap stream size; 0 disables trimming")
    return p.parse_args()


def main():
    args = parse_args()
    r = redis.from_url(args.url)

    print(f"=== loadgen ===")
    print(f"  target: {args.url}  stream={args.stream}")
    print(f"  count={args.count:,}  batch={args.batch}  maxlen={args.trim or 'unbounded'}")

    start = time.time()
    pipe  = r.pipeline(transaction=False)
    flushed = 0

    for i in range(args.count):
        fields = {
            "op":    "set",
            "key":   f"{args.prefix}{i}",
            "value": f"v:{i}:{int(time.time() * 1000)}",
        }
        if args.trim:
            pipe.xadd(args.stream, fields, maxlen=args.trim, approximate=True)
        else:
            pipe.xadd(args.stream, fields)

        if (i + 1) % args.batch == 0:
            pipe.execute()
            flushed = i + 1
            if flushed % (args.batch * 10) == 0:
                rate = flushed / (time.time() - start)
                print(f"  sent={flushed:,}  rate={rate:,.0f}/s")

    if flushed < args.count:
        pipe.execute()

    elapsed = time.time() - start
    print(f"DONE: sent={args.count:,}  elapsed={elapsed:.1f}s  "
          f"rate={args.count/elapsed:,.0f}/s")


if __name__ == "__main__":
    main()
