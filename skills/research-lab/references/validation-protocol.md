# Validation protocol

A lab is not done until `scripts/validate_lab.sh` exits 0 against it. The script is the single source of truth for "does it work."

## What `validate_lab.sh` does

```
1. docker compose config -q                  # schema/YAML check, fail fast
2. host-isolation grep checklist             # see host-isolation-rules.md
3. docker compose up -d --wait               # relies on healthchecks; bounded by compose timeout
4. bash scripts/smoke-test.sh                # lab-specific property assertion
5. docker compose down -v                    # always runs, via trap, even on failure
6. exit ${SMOKE_EXIT_CODE}                   # propagates the smoke test's exit
```

Step 5 runs unconditionally — a failed run does not leave dangling state.

## Smoke test contract (recap)

Each lab provides its own `scripts/smoke-test.sh`. The script must:

- Exit 0 only if the **demonstrated property** was observed. Not "the process is running" — the actual property.
- Bound its wall-clock runtime to 60s by default. Use `timeout` or an explicit loop with a counter.
- On success, print a single sentence describing what it observed.
- On failure, print the last 50 log lines from each service.

If the property is "subscriber receives messages from publisher", the smoke test publishes a known payload, subscribes, and asserts the payload was delivered — by reading actual logs or by running a verifier client. Checking `redis-cli ping` returns PONG is *not* a smoke test for pub/sub.

## Failure handling discipline

When `validate_lab.sh` fails:

1. **Read logs first.** `docker compose logs --tail=100 <service>`. Form a hypothesis from evidence, not from guessing.
2. **Fix the root cause.** Forbidden shortcuts:
   - Increasing timeouts to mask a race condition.
   - Removing healthchecks to "fix" startup.
   - Weakening the smoke test to make it pass.
   - Adding `restart: always` to make a flaky service look stable.
   These are all forms of hiding the failure.
3. **Tear down between attempts.** `docker compose down -v` before retrying with code changes, so stale volumes can't mask a fix.
4. **Three-strike rule.** After 3 failed attempts on the same root cause, escalate: invoke `superpowers:systematic-debugging` rather than continuing to guess.
5. **If the property genuinely cannot be demonstrated as designed,** go back to the Design stage. Adjust the topology or the property statement — don't paper over.

## What "validated" means

The lab is validated when:

- `validate_lab.sh` exits 0.
- The smoke test's success message accurately describes what was observed.
- No containers, volumes, or networks remain on the host after the run.
- `git status` in the lab dir is clean (no debug artifacts left behind).

Anything less and the lab ships unfinished.
