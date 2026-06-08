#!/usr/bin/env bash
# Runs both LWW proofs (A: deterministic mechanism; B: end-to-end at each rate in
# REPORT_RATES) and writes a self-contained HTML report to reports/lww-report.html.
# Requires the chart to be installable on the current kube-context (verify-lww.sh
# boots it idempotently) and `jq`.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

RATES="${REPORT_RATES:-5000 20000}"
OUT="${OUT:-reports/lww-report.html}"
VERIFY_CMD="${VERIFY_CMD:-${SCRIPT_DIR}/verify-lww.sh}"   # overridable for testing the report renderer
mkdir -p "$(dirname "$OUT")"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CONNECT_IMG="$(awk '/^connect:/{f=1} f&&/image:/{print $2; exit}' chart/values.yaml)"

PROOFA_LINE=""
declare -a ROWS=()
OVERALL="PASS"
PEAK=0
MAXMM=0          # worst (max) mismatches observed across runs
declare -a FAILS=()

for rate in $RATES; do
  echo "[report] running proofs at rate=${rate}…" >&2
  out="$(RATE="${rate}" "${VERIFY_CMD}" 2>&1 || true)"
  # Proof A line (same each run; capture once).
  if [[ -z "$PROOFA_LINE" ]]; then
    PROOFA_LINE="$(printf '%s\n' "$out" | grep -m1 'results (want' || true)"
  fi
  pa_pass=$(printf '%s\n' "$out" | grep -qm1 '\[proofA\] PASS' && echo yes || echo no)
  json="$(printf '%s\n' "$out" | sed -n 's/^\[proofB\] //p' | grep '^{' | tail -n1 || true)"
  if [[ -z "$json" ]]; then
    ROWS+=("<tr class=fail><td>${rate}</td><td colspan=7>NO RESULT (proofB produced no verdict)</td></tr>")
    OVERALL="FAIL"; FAILS+=("rate ${rate}: Proof B produced no verdict"); continue
  fi
  read -r ra st du mm rg wpk pass reason <<<"$(printf '%s' "$json" | jq -r '[.lww.rate_achieved_avg, .lww.stale, .lww.duplicate, .lww.mismatches, .lww.regressions, .lww.writes_per_key_avg, .verdict.pass, (.verdict.reason//"")] | @tsv')"
  (( mm > MAXMM )) && MAXMM=$mm
  cls=$([[ "$pass" == "true" && "$pa_pass" == "yes" ]] && echo ok || echo fail)
  if [[ "$cls" != "ok" ]]; then
    OVERALL="FAIL"
    FAILS+=("rate ${rate}: ${reason:-verdict failed}")
  fi
  ra_fmt=$(printf '%.0f' "$ra")
  wpk_fmt=$(printf '%.0f' "$wpk")
  [[ "$cls" == "ok" ]] && (( ra_fmt > PEAK )) && PEAK=$ra_fmt
  verdict_txt=$([[ "$pass" == "true" ]] && echo "PASS" || echo "FAIL: ${reason}")
  ROWS+=("<tr class=${cls}><td>${rate}</td><td>${ra_fmt}</td><td class=good>${st}</td><td>${du}</td><td class=$([[ $mm == 0 ]] && echo good || echo bad)>${mm}</td><td>${rg}</td><td>${wpk_fmt}</td><td>${verdict_txt}</td></tr>")
done

# The line is "[proofA] results (want: 1 0 0 -1 3 v3): <actual>"; take after the LAST "): ".
PROOFA_RESULT="${PROOFA_LINE##*): }"
PA_CLS=$([[ "$PROOFA_RESULT" == "1 0 0 -1 3 v3" ]] && echo ok || echo fail)
if [[ "$PA_CLS" != "ok" ]]; then
  OVERALL="FAIL"
  FAILS+=("Proof A mechanism check returned '${PROOFA_RESULT:-<none>}' (expected '1 0 0 -1 3 v3')")
fi
BANNER_CLS=$([[ "$OVERALL" == "PASS" ]] && echo bpass || echo bfail)

# Status-driven (never hard-coded) cards + conclusion, so a FAILING run can never
# emit a success claim.
MM_CLS=$([[ "$MAXMM" == 0 ]] && echo good || echo bad)
PEAK_TXT=$([[ "$PEAK" -gt 0 ]] && echo "${PEAK}/s" || echo "—")
if [[ "$OVERALL" == "PASS" ]]; then
  CONCLUSION="<p>The sink-side last-write-wins compare-and-set fence is <b>verified</b>: stale writes can never overwrite newer ones at the Redis KV sink, regardless of arrival order, while a single connect-sink pod sustains the rates above with zero LWW violations. The achieved rate tracking the target with thousands of fenced stale writes and no backlog indicates the true single-instance ceiling is higher than the writer's cap.</p>"
else
  items=""
  for f in "${FAILS[@]}"; do items+="<li>$(printf '%s' "$f" | sed 's/&/\&amp;/g; s/</\&lt;/g')</li>"; done
  [[ -z "$items" ]] && items="<li>see the tables above</li>"
  CONCLUSION="<p class=bad>Verification FAILED — these results do NOT confirm the last-write-wins fence. Do not rely on them. Failing checks:</p><ul>${items}</ul>"
fi

cat > "$OUT" <<HTML
<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1">
<title>Last-Write-Wins — Verification Report</title>
<style>
 body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;background:#0e1117;color:#e6e6e6;line-height:1.5}
 .wrap{max-width:980px;margin:0 auto;padding:28px}
 h1{font-size:22px;margin:0 0 4px;color:#fff} h2{font-size:15px;color:#b8c2cc;margin:26px 0 8px;border-bottom:1px solid #2a2f3a;padding-bottom:4px}
 .sub{color:#8b95a3;font-size:13px;margin-bottom:18px}
 .banner{padding:14px 18px;border-radius:8px;font-size:18px;font-weight:600;margin:8px 0 4px}
 .bpass{background:#102a14;color:#7ee787;border:1px solid #2ea043} .bfail{background:#2d1011;color:#f85149;border:1px solid #da3633}
 table{border-collapse:collapse;width:100%;font-size:13px;margin-top:6px} th,td{border-bottom:1px solid #2a2f3a;padding:7px 10px;text-align:left}
 th{background:#161b22;color:#b8c2cc;font-weight:500} tr.ok td:last-child{color:#7ee787} tr.fail td:last-child{color:#f85149}
 .good{color:#7ee787} .bad{color:#f85149;font-weight:600}
 code{background:#161b22;padding:1px 5px;border-radius:3px;font-size:12px}
 .cards{display:flex;gap:12px;flex-wrap:wrap;margin:10px 0}
 .card{background:#161b22;border:1px solid #2a2f3a;border-radius:8px;padding:12px 16px;min-width:150px}
 .card .k{font-size:11px;color:#8b95a3;text-transform:uppercase;letter-spacing:.04em} .card .v{font-size:22px;margin-top:4px;color:#fff}
 p{font-size:13px;color:#c5ccd3} li{font-size:13px;color:#c5ccd3}
</style></head><body><div class=wrap>
<h1>Redis → Connect — Last-Write-Wins verification</h1>
<div class=sub>Single-instance Kubernetes lab · generated ${TS} · connect image <code>${CONNECT_IMG}</code></div>
<div class="banner ${BANNER_CLS}">Overall: ${OVERALL}</div>

<div class=cards>
 <div class=card><div class=k>Mechanism (Proof A)</div><div class=v>${PA_CLS^^}</div></div>
 <div class=card><div class=k>Peak passing rate</div><div class=v>${PEAK_TXT}</div></div>
 <div class=card><div class=k>Correctness</div><div class="v ${MM_CLS}">mismatches ${MAXMM}</div></div>
</div>

<h2>Proof A — deterministic mechanism (direct to redis-region)</h2>
<p>Apply versions <b>3, 1, 2</b> to one key in that arrival order, then replay version 3.
Expect the CAS to return <code>1 0 0 -1</code> (applied / stale / stale / duplicate) and the
stored value to be the version-3 write.</p>
<table><tr><th>arrival</th><th>v3</th><th>v1</th><th>v2</th><th>v3 (replay)</th><th>final ver</th><th>final val</th></tr>
<tr class=${PA_CLS}><td>returns →</td><td>$(echo "$PROOFA_RESULT" | awk '{print $1}')</td><td>$(echo "$PROOFA_RESULT" | awk '{print $2}')</td><td>$(echo "$PROOFA_RESULT" | awk '{print $3}')</td><td>$(echo "$PROOFA_RESULT" | awk '{print $4}')</td><td>$(echo "$PROOFA_RESULT" | awk '{print $5}')</td><td>$(echo "$PROOFA_RESULT" | awk '{print $6}')</td></tr></table>
<p><b>Pass criterion:</b> a correct fence returns <code>1 &nbsp; 0 &nbsp; 0 &nbsp; -1</code> and leaves <code>ver=3, val=v3</code> — rejecting the two lower-version (stale) writes and the equal-version (duplicate) replay so that the highest version would win irrespective of arrival order. The row above is the <i>observed</i> result; the overall banner reflects whether it matched.</p>

<h2>Proof B — end-to-end under real reordering</h2>
<p>Drive the writer through the full parallel pipeline (connect-source <code>max_in_flight=256</code>,
connect-sink <code>threads=4</code>), which reorders same-key messages. After quiescence, every key's
stored version is compared to the writer's source max.</p>
<table>
<tr><th>target msg/s</th><th>achieved/s</th><th>stale (reorder fenced)</th><th>duplicate</th><th>mismatches</th><th>regressions</th><th>writes/key</th><th>verdict</th></tr>
$(printf '%s\n' "${ROWS[@]}")
</table>
<ul>
<li><b>Why <code>stale &gt; 0</code> is required:</b> a strictly-older version can only arrive after a higher one was stored under genuine same-key reordering, so a non-zero <code>stale</code> count is what proves reordering was exercised and the fence rejected the loser. A run with <code>stale = 0</code> is ruled <i>inconclusive</i>, not a pass.</li>
<li><b>Why <code>mismatches = 0</code> is required:</b> a pass demands that every key's final stored version equal the highest the writer sent — no stale write won. The per-rate table above carries the <i>observed</i> mismatch count; any non-zero value fails the verdict loudly.</li>
<li>The verdict additionally requires the §3.4.1 preconditions (fresh per-run key namespace ⇒ empty store, single non-restarting writer, windowed counter deltas) so that <code>stale&gt;0</code> is unambiguous.</li>
</ul>

<h2>Conclusion</h2>
${CONCLUSION}
</div></body></html>
HTML

echo "[report] wrote ${OUT} (overall: ${OVERALL})"
