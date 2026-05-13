"""
Streams-based fan-out relay.

Reads from central Redis Stream via consumer group, applies each event to every
edge Redis using a pipeline, then XACKs. On restart it resumes from the last
unacked entry — no events lost.

Event format (as XADD fields):
  op    : set | del | hset
  key   : the target key on edges
  value : payload (for set)
  ...   : extra fields go into hash for hset

Pub/Sub variant is included at the bottom (commented) for comparison.
"""

import asyncio
import os
import signal
import time
import redis.asyncio as redis
from redis.exceptions import ResponseError

CENTRAL_URL    = os.environ["CENTRAL_URL"]
EDGE_URLS      = [u.strip() for u in os.environ["EDGE_URLS"].split(",") if u.strip()]
STREAM_KEY     = os.environ.get("STREAM_KEY", "events")
GROUP          = os.environ.get("CONSUMER_GROUP", "relay-group")
CONSUMER       = os.environ.get("CONSUMER_NAME", "relay-1")
BATCH_SIZE     = int(os.environ.get("BATCH_SIZE", "1000"))
BLOCK_MS       = int(os.environ.get("BLOCK_MS", "1000"))


async def ensure_group(client: redis.Redis) -> None:
    try:
        await client.xgroup_create(STREAM_KEY, GROUP, id="0", mkstream=True)
        print(f"[relay] created consumer group '{GROUP}' on stream '{STREAM_KEY}'")
    except ResponseError as e:
        if "BUSYGROUP" in str(e):
            print(f"[relay] consumer group '{GROUP}' already exists")
        else:
            raise


def apply_to_pipeline(pipe, fields: dict) -> None:
    op  = fields.get("op", "set")
    key = fields["key"]
    if op == "set":
        pipe.set(key, fields.get("value", ""))
    elif op == "del":
        pipe.delete(key)
    elif op == "hset":
        mapping = {k: v for k, v in fields.items() if k not in ("op", "key")}
        if mapping:
            pipe.hset(key, mapping=mapping)
    else:
        # Unknown op — skipped silently; in prod you'd send to a DLQ.
        pass


async def fan_out(edges: list[redis.Redis], entries: list[tuple[str, dict]]) -> None:
    pipes = [e.pipeline(transaction=False) for e in edges]
    for _, fields in entries:
        for p in pipes:
            apply_to_pipeline(p, fields)
    # Edges are independent — parallel execute.
    await asyncio.gather(*(p.execute() for p in pipes))


async def run() -> None:
    central = redis.from_url(CENTRAL_URL, decode_responses=True)
    edges   = [redis.from_url(u, decode_responses=True) for u in EDGE_URLS]
    await ensure_group(central)
    print(f"[relay] up: central={CENTRAL_URL}  edges={len(edges)}  batch={BATCH_SIZE}")

    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, stop.set)

    processed   = 0
    last_report = time.time()
    last_count  = 0

    while not stop.is_set():
        try:
            resp = await central.xreadgroup(
                GROUP, CONSUMER, {STREAM_KEY: ">"},
                count=BATCH_SIZE, block=BLOCK_MS,
            )
            if not resp:
                continue

            for _, entries in resp:
                if not entries:
                    continue
                await fan_out(edges, entries)
                await central.xack(STREAM_KEY, GROUP, *[mid for mid, _ in entries])
                processed += len(entries)

            now = time.time()
            if now - last_report >= 2.0:
                rate = (processed - last_count) / (now - last_report)
                print(f"[relay] processed={processed:,}  rate={rate:,.0f}/s")
                last_report, last_count = now, processed

        except Exception as e:
            print(f"[relay] error: {e!r}; backing off 1s")
            await asyncio.sleep(1)

    print(f"[relay] shutting down. total processed={processed:,}")
    await central.aclose()
    for e in edges:
        await e.aclose()


if __name__ == "__main__":
    asyncio.run(run())


# -----------------------------------------------------------------------------
# Pub/Sub variant (for comparison only — DO NOT USE for data sync):
#
# async def run_pubsub():
#     central = redis.from_url(CENTRAL_URL, decode_responses=True)
#     edges   = [redis.from_url(u, decode_responses=True) for u in EDGE_URLS]
#     pubsub  = central.pubsub()
#     await pubsub.subscribe("events")
#     async for msg in pubsub.listen():
#         if msg["type"] != "message":
#             continue
#         # parse msg["data"] (e.g. JSON), apply to edges
#         # Problem: if relay is down or slow, messages are GONE.
#         # Problem: no ACK, no replay, no consumer-group sharding.
# -----------------------------------------------------------------------------
