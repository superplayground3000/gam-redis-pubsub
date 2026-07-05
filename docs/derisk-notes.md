# Task 1.1 — Empirical de-risk notes

Verified on the existing kind cluster **`rrcs`** (context `kind-rrcs`) on 2026-06-04.
Tooling: kind v0.31, helm v3.21, kubectl v1.36, docker.
Images: `redis:7.4-alpine`, `hpdevelop/connect:4.92.0-claudefix`
(reports `benthos_version=4.92.0-SNAPSHOT-8b54f6e1a`).

All throwaway probe pods were deleted after the run. The cluster is left running.

---

## Finding 1 — HSET fires a keyspace event on `__keyevent@0__:hset`

**Result: CONFIRMED.** With `notify-keyspace-events KEA`, an `HSET` (the LWW store uses a
hash, not `SET`) fires an event on channel **`__keyevent@0__:hset`** with payload =
**the key name**.

Method: throwaway `redis:7.4-alpine` pod, `redis-server --notify-keyspace-events KEA`,
background `psubscribe "__keyevent@0__:*"`, then `HSET k ver 1 val hello`.

Observed psubscribe output:

```
pmessage
__keyevent@0__:*
__keyevent@0__:hset      <- channel
k                        <- payload = the key name
```

So the dashboard subscriber should `PSUBSCRIBE __keyevent@0__:hset` (or the broader
`__keyevent@0__:*`) and treat the message payload as the applied key name.
(DB index 0 — adjust the `@0__` segment if a non-zero DB is ever used.)

---

## Finding 2 — Connect entrypoint command

**Result: `redpanda-connect run <file>`.**

The binary lives at the image root: **`/redpanda-connect`** (338 MB, root-owned, executable).
`run` is a real subcommand: `redpanda-connect run - Run Redpanda Connect ... against a
specified config file`. The image also ships a default `/connect.yaml`.

Evidence:

```
$ ls /            -> ... connect.yaml ... redpanda-connect ...
$ /redpanda-connect --version
Version: 4.92.0-SNAPSHOT-8b54f6e1a
$ /redpanda-connect run --help
NAME:
   redpanda-connect run - Run Redpanda Connect in normal mode against a specified config file
USAGE:
   redpanda-connect run [command options]
```

The parent chart's `args: ["run","/connect.yaml"]` is correct as-is. There is **no**
`redpanda-connect`/`connect`/`rpk` on `$PATH` (no `which` hit) — invoke the absolute path
`/redpanda-connect` if a custom command is set, otherwise rely on the image entrypoint +
`args: ["run", "<file>"]`.

Note: the connect image does **not** contain `redis-server`/`redis-cli`. The probe ran
connect and redis as two containers in one pod (shared `127.0.0.1`).

---

## Finding 3 — `command: eval` in the `redis` processor

**Result: `command: eval` WORKS.** The LWW CAS can be done with the built-in `redis`
processor and an inline Lua script — no `script_load`/`evalsha` dance required.

### What works
- `command: eval` + `args_mapping` returning `[script, numkeys, key, value, version]` runs
  and returns the integer the Lua script returns.
- The script applied/rejected writes correctly (CAS verified against real Redis state).

### What does NOT exist (correction to the starting assumption)
- **There is no `result_map` field on the `redis` processor in this version.** Using it is a
  hard lint error and connect refuses to start:

  ```
  level=error msg="Config lint error" lint="...field result_map not recognised"
  level=error msg="shutting down due to linter errors..."
  ```

  The `redis` processor template (`redpanda-connect create stdin/redis/stdout`) only exposes:
  `url, kind, master, client_name, tls, command, args_mapping, retries, retry_period`.

### How the result is actually returned (use this instead of `result_map`)
The eval result **replaces the message content/body**. Inspecting the post-`redis` message:

```
{"raw_content":"1","this_type":"number","this_val":1}
```

i.e. after the `redis` processor, `content().string()` == `"1"` and `this` == `1` (a number).
To lift it into metadata, add a **following `mapping` processor**:

```yaml
- mapping: 'meta lww_applied = this'
```

(Capture into metadata in its own processor **before** you rebuild `root`; doing
`meta x = content().string()` and reassigning `root` in the *same* mapping yielded `null` in
testing — split them.)

### Bloblang gotcha
The inline Lua contains `;` which breaks the single-line `root = [ "...;...", 1, ... ]`
array form (lint: `expected line break, got: ; roo`). Bind the script to a variable first:

```yaml
args_mapping: |
  let script = "local cur = redis.call('HGET', KEYS[1], 'ver'); if cur==false or tonumber(ARGV[2])>tonumber(cur) then redis.call('HSET', KEYS[1],'val',ARGV[1],'ver',ARGV[2]); return 1 end; return 0"
  root = [ $script, 1, meta("k"), content().string(), meta("ver") ]
```

### Working processor block (verified)
```yaml
pipeline:
  processors:
    - mapping: |
        meta k = this.k
        meta ver = this.ver
        root = this.v
    - redis:
        url: redis://127.0.0.1:6379
        command: eval
        args_mapping: |
          let script = "local cur = redis.call('HGET', KEYS[1], 'ver'); if cur==false or tonumber(ARGV[2])>tonumber(cur) then redis.call('HSET', KEYS[1],'val',ARGV[1],'ver',ARGV[2]); return 1 end; return 0"
          root = [ $script, 1, meta("k"), content().string(), meta("ver") ]
    - mapping: 'meta lww_applied = this'
```

### Evidence — CAS sequence (apply 5, reject stale 3)
```
{"k":"probe","lww_applied":"1","ver":"5"}    <- ver 5 applied
{"k":"probe","lww_applied":"0","ver":"3"}    <- stale ver 3 rejected

redis HGETALL probe -> val=first  ver=5      <- stale write did not land
```

### Fallback (NOT needed, but available)
This image also ships a dedicated **`redis_script`** processor
(`script` + `args_mapping` + `keys_mapping`, all required) which is the idiomatic
`script_load`/`evalsha`-with-fallback path. Since plain `eval` works, the simpler `redis` +
`command: eval` block above is the chosen approach. Keep `redis_script` in mind only if we
later want connect to manage the SHA cache.

---

## Summary for downstream tasks
1. Dashboard subscribes to **`__keyevent@0__:hset`**, payload = key name.
2. Connect entrypoint: **`redpanda-connect run <file>`** (binary `/redpanda-connect`;
   chart `args: ["run","/connect.yaml"]` is correct).
3. **`command: eval` works.** No `result_map` — capture the result with a trailing
   `- mapping: 'meta lww_applied = this'`. Bind the Lua script to a `let` var to dodge the
   `;` lint error.
