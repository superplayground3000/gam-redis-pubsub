#!/usr/bin/env bash
# Behavioral got-vs-want test of the DLQ hash guard in the RENDERED chart pipeline
# (rules/50-lessons.md 2026-07-15: render-level greps prove presence, never semantics —
# any Helm-templated Bloblang ships a behavioral test that runs the REAL pipeline).
#
# Extracts the reverse pipeline's stash+guard mapping from the DLQ-ENABLED chart
# render, runs it in the pinned Connect image (stdin -> stdout, no redis/nats
# needed for the mapping stage), and asserts hash_decode_failed / event_id for a
# case table: plain + gzip:base64-encoded poison (JSON array / scalar), valid
# object bodies, and the guard's skip paths (type=string, delete).
#
# Why this exists: the guard's decode-OK precondition MUST be derived from lets,
# not meta("decode_failed") read in the same mapping — at runtime this build reads
# same-mapping meta as-of mapping ENTRY, so the meta form silently never fires
# (A/B-verified 2026-07-16; blobl CLI masks it). This test fails on that form.
#
# Usage: scripts/test-dlq-guard.sh   (CONNECT_IMG to override the pinned image)
set -euo pipefail
cd "$(dirname "$0")/.."

CONNECT_IMG="${CONNECT_IMG:-hpdevelop/connect:4.92.0-claudefix}"
command -v docker >/dev/null 2>&1 || { echo "[test-dlq-guard] docker not available"; exit 2; }
docker image inspect "$CONNECT_IMG" >/dev/null 2>&1 || { echo "[test-dlq-guard] $CONNECT_IMG not present locally"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "[test-dlq-guard] python3 not available"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Capture once to a file, then feed python (never pipe a big render into an
# early-exit reader under pipefail — rules/50-lessons.md 2026-07-07; and a
# <<<herestring cannot be combined with the <<heredoc that carries the script).
helm template chart/ --set connect.deadLetter.enabled=true > "$TMP/render.yaml"

python3 - "$TMP" <<'PYEOF' || { echo "[test-dlq-guard] failed to build test config"; exit 1; }
import sys, yaml, json, base64, gzip
tmp = sys.argv[1]
pipe = None
for d in yaml.safe_load_all(open(f"{tmp}/render.yaml")):
    if d and d.get("kind") == "ConfigMap":
        for k, v in (d.get("data") or {}).items():
            if v and "hash_decode_failed" in v and "reject_errored" in v:
                pipe = yaml.safe_load(v)
assert pipe, "enabled reverse pipeline ConfigMap not found in render"
stash = pipe["pipeline"]["processors"][0]
assert "mapping" in stash, "first processor is not the stash mapping"
cfg = {
    "input": {"stdin": {}},
    "pipeline": {"processors": [
        stash,
        {"mapping": 'root = {"hash_decode_failed": meta("hash_decode_failed").or("UNSET"),'
                    ' "event_id_set": meta("event_id").or("") != "", "case": this.kv_key}'},
    ]},
    "output": {"stdout": {}},
}
yaml.safe_dump(cfg, open(f"{tmp}/cfg.yaml", "w"))
enc = lambda s: base64.b64encode(gzip.compress(s.encode())).decode()
cases = [
    {"op": "create", "type": "hash", "kv_key": "plain_poison_array", "body": '["a","b"]', "event_id": "E1", "ts": 1},
    {"op": "create", "type": "hash", "kv_key": "plain_ok_object", "body": '{"f":"v"}', "event_id": "E2", "ts": 1},
    {"op": "create", "type": "hash", "kv_key": "enc_poison_scalar", "enc": "gzip:base64", "body": enc('"5566"'), "event_id": "E3", "ts": 1},
    {"op": "create", "type": "hash", "kv_key": "enc_ok_object", "enc": "gzip:base64", "body": enc('{"f":"v"}'), "event_id": "E4", "ts": 1},
    {"op": "create", "type": "string", "kv_key": "string_skip", "body": "whatever", "event_id": "E5", "ts": 1},
    {"op": "delete", "kv_key": "delete_skip", "event_id": "E6"},
]
open(f"{tmp}/cases.jsonl", "w").write("\n".join(json.dumps(c) for c in cases) + "\n")
PYEOF

docker run --rm -i -v "$TMP/cfg.yaml:/cfg.yaml:ro" "$CONNECT_IMG" run /cfg.yaml < "$TMP/cases.jsonl" 2>/dev/null > "$TMP/got.jsonl"

python3 - "$TMP" <<'PYEOF'
import sys, json
sys.stdin = open(f"{sys.argv[1]}/got.jsonl")
want = {"plain_poison_array": "yes", "plain_ok_object": "no", "enc_poison_scalar": "yes",
        "enc_ok_object": "no", "string_skip": "no", "delete_skip": "no"}
got = {}
for line in sys.stdin:
    line = line.strip()
    if line.startswith("{"):
        r = json.loads(line)
        got[r["case"]] = r
bad = 0
for c, w in want.items():
    g = got.get(c)
    if not g:
        print(f"[test-dlq-guard] MISSING case {c} (mapping errored the message?)"); bad += 1; continue
    ok = g["hash_decode_failed"] == w and g["event_id_set"]
    print(f"[test-dlq-guard] {'PASS' if ok else 'FAIL'} {c}:"
          f" hash_decode_failed={g['hash_decode_failed']} want={w} event_id_set={g['event_id_set']}")
    bad += 0 if ok else 1
sys.exit(1 if bad else 0)
PYEOF
echo "[test-dlq-guard] PASS"
