# redis-streams-multigroup-fanout

## What this demonstrates

Multiple Redis Streams consumer groups each independently read every message from one stream — one `XADD` produces a message that is observed once by each group.

## Run it

```bash
cp .env.example .env             # only if you want to override defaults
docker compose up -d --wait
docker compose logs -f --tail=20 producer consumer-a consumer-b consumer-c
```

The producer writes `MAX_MESSAGES` entries (default 10) over `MAX_MESSAGES × INTERVAL_MS` milliseconds and then exits. Each of the three consumers (one per group) prints `received id=<id> n=<n>` for every entry.

## Expected output

You should see, for each consumer service, one line per produced entry — same IDs across all three:

```
consumer-a-1  | received id=1715690000000-0 n=1
consumer-a-1  | received id=1715690001000-0 n=2
...
consumer-b-1  | received id=1715690000000-0 n=1
consumer-b-1  | received id=1715690001000-0 n=2
...
consumer-c-1  | received id=1715690000000-0 n=1
...
```

The producer's lines look like `produced n=1 id=...` and match what each consumer reports.

## Teardown

```bash
docker compose down -v
```

## Further reading

- [Redis Streams introduction](https://redis.io/docs/latest/develop/data-types/streams/) — primary.
- [Streams tutorial](https://redis.io/docs/latest/develop/data-types/streams-tutorial/) — primary, longer-form.
- See `RESEARCH.md` in this directory for the design decisions and what is deliberately excluded.
