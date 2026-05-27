#!/usr/bin/env python3
"""Generate an HTML dashboard from all reports/*.json.

Reads every JSON report in `reports/`, groups by tier and mode, and writes
a self-contained HTML file (`reports/dashboard.html`) with batch-vs-single
comparison charts for rate achievement, packet loss, and sync latency,
plus a full per-run table.

Usage:
    python3 scripts/dashboard.py
    # then open reports/dashboard.html in a browser
"""
import json
import sys
import time
from pathlib import Path

LAB_DIR = Path(__file__).resolve().parent.parent
REPORTS_DIR = LAB_DIR / "reports"


def load_reports():
    reports = []
    for path in sorted(REPORTS_DIR.glob("*.json")):
        try:
            with open(path) as f:
                r = json.load(f)
            r["_filename"] = path.name
            reports.append(r)
        except (json.JSONDecodeError, OSError) as e:
            print(f"WARN: skipping {path.name}: {e}", file=sys.stderr)
    return reports


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>redis-redpanda-throughput-stress dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  :root {
    --batch: #1976d2;
    --single: #f57c00;
    --pass: #2e7d32;
    --fail: #c62828;
    --bg: #fafafa;
    --card: #ffffff;
    --border: #e0e0e0;
    --text: #212121;
    --muted: #757575;
  }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    max-width: 1200px;
    margin: 0 auto;
    padding: 2rem 1rem;
    background: var(--bg);
    color: var(--text);
  }
  h1 { margin: 0 0 0.25rem 0; font-size: 1.6rem; }
  .subtitle { color: var(--muted); margin: 0 0 1.5rem 0; font-size: 0.95rem; }
  .summary { display: flex; flex-wrap: wrap; gap: 1rem; margin: 1.5rem 0; }
  .stat {
    background: var(--card);
    padding: 0.9rem 1.2rem;
    border: 1px solid var(--border);
    border-radius: 8px;
    min-width: 120px;
    flex: 0 0 auto;
  }
  .stat-value { font-size: 1.6rem; font-weight: 600; line-height: 1.1; }
  .stat-label { color: var(--muted); font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; }
  section {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 1.25rem 1.5rem;
    margin: 1.25rem 0;
  }
  h2 { margin: 0 0 0.5rem 0; font-size: 1.1rem; }
  .note { color: var(--muted); font-size: 0.85rem; margin: 0 0 1rem 0; }
  .chart-container { position: relative; height: 340px; margin-top: 0.5rem; }
  table { width: 100%; border-collapse: collapse; margin-top: 0.5rem; font-size: 0.88rem; }
  th {
    background: #f5f5f5;
    padding: 0.6rem 0.5rem;
    text-align: left;
    border-bottom: 2px solid var(--border);
    font-weight: 600;
  }
  td {
    padding: 0.55rem 0.5rem;
    border-bottom: 1px solid #f0f0f0;
    font-variant-numeric: tabular-nums;
  }
  tr:hover td { background: #fafafa; }
  .pass { color: var(--pass); font-weight: 600; }
  .fail { color: var(--fail); font-weight: 600; }
  .num { text-align: right; }
  .muted { color: var(--muted); }
  .mode-batch { color: var(--batch); font-weight: 600; }
  .mode-single { color: var(--single); font-weight: 600; }
  .legend-swatch {
    display: inline-block; width: 12px; height: 12px;
    border-radius: 2px; margin-right: 0.3rem; vertical-align: middle;
  }
  .legend-line {
    display: inline-block; width: 18px; height: 0;
    border-top: 2px dashed #666; margin-right: 0.3rem; vertical-align: middle;
  }
  .banner {
    background: #fff3e0;
    border: 1px solid #ffb74d;
    border-left: 4px solid #f57c00;
    border-radius: 6px;
    padding: 0.75rem 1rem;
    margin: 1rem 0;
    font-size: 0.9rem;
    color: #5d4037;
  }
  .banner strong { color: #bf360c; }
  .ago-stale { color: var(--fail); }
  footer { margin-top: 2rem; color: var(--muted); font-size: 0.8rem; text-align: center; }
</style>
</head>
<body>
<h1>redis-redpanda-throughput-stress &mdash; matrix dashboard</h1>
<p class="subtitle">
  <span class="legend-swatch" style="background:var(--batch)"></span>batch
  &nbsp;&nbsp;
  <span class="legend-swatch" style="background:var(--single)"></span>single
  &nbsp;&nbsp;
  <span class="legend-line"></span>SLO threshold
  &nbsp;&middot;&nbsp; comparison across all tiers in reports/
</p>

<div id="vintageBanner"></div>
<div class="summary" id="summary"></div>

<section>
  <h2>Rate achieved (% of target)</h2>
  <p class="note">Higher is better. 100% = writer fully sustained target rate during the sustain window. Dashed line marks each tier's `rate_min_pct` floor.</p>
  <div class="chart-container"><canvas id="rateChart"></canvas></div>
</section>

<section>
  <h2>Packet loss (missing_pct)</h2>
  <p class="note">Lower is better. ALO mode expects 0% loss; any non-zero value is real in-transit loss between writer and regional Redis. Trimmed entries (capped by MAXLEN) are NOT counted as loss.</p>
  <div class="chart-container"><canvas id="lossChart"></canvas></div>
</section>

<section>
  <h2>Sync latency p99 (ms, log scale)</h2>
  <p class="note">applied_ms &minus; t_send_ms per event, 99th percentile. Lower is better. Dashed line per tier shows the calibrated p99 ceiling from `tier-defs.sh`.</p>
  <div class="chart-container"><canvas id="p99Chart"></canvas></div>
</section>

<section>
  <h2>Latency percentile distribution</h2>
  <p class="note">Each line is one tier&times;mode combination. Click legend entries to hide/show. Solid = batch, dashed = single. Log scale on Y to show p50 and max together.</p>
  <div class="chart-container" style="height:400px"><canvas id="percentileChart"></canvas></div>
</section>

<section>
  <h2>Full table</h2>
  <p class="note">All fields from every report. Verdict reason in parens when failed.</p>
  <div style="overflow-x:auto">
    <table id="reportTable">
      <thead>
        <tr>
          <th>Tier</th>
          <th>Mode</th>
          <th class="num">Rate ach./target</th>
          <th class="num">Rate %</th>
          <th class="num">Sent</th>
          <th class="num">Received</th>
          <th class="num">Missing</th>
          <th class="num">Loss %</th>
          <th class="num">Trimmed</th>
          <th class="num">p50</th>
          <th class="num">p99</th>
          <th class="num">p999</th>
          <th class="num">max</th>
          <th class="num">Ceiling</th>
          <th>Verdict</th>
          <th class="num">Age</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
  </div>
</section>

<footer>
  Generated from <code>__COUNT__</code> reports. Re-run <code>python3 scripts/dashboard.py</code> after each matrix run.
</footer>

<script>
const REPORTS = __DATA__;
const GENERATED_AT_MS = __GENERATED_AT_MS__;

// Sort by tier then mode (batch first per tier).
REPORTS.sort((a, b) => a.tier - b.tier || a.mode.localeCompare(b.mode));

const tiers = [...new Set(REPORTS.map(r => r.tier))].sort((a, b) => a - b);
const COLORS = { batch: '#1976d2', single: '#f57c00' };
const THRESHOLD_COLOR = '#555';

function get(tier, mode) {
  return REPORTS.find(r => r.tier === tier && r.mode === mode);
}

// Return the SLO values for a tier (same across both modes of one tier).
function sloFor(tier) {
  const r = get(tier, 'batch') || get(tier, 'single');
  return r ? r.slo : null;
}

function bymode(field) {
  return ['batch', 'single'].map(mode => ({
    type: 'bar',
    label: mode,
    data: tiers.map(t => {
      const r = get(t, mode);
      return r ? field(r) : null;
    }),
    backgroundColor: COLORS[mode],
    borderColor: COLORS[mode],
    order: 2,
  }));
}

// Build a horizontal threshold-line dataset (one Y value per tier; null breaks the line).
function thresholdDataset(label, perTierValue, opts) {
  opts = opts || {};
  return {
    type: 'line',
    label: label,
    data: tiers.map(perTierValue),
    borderColor: THRESHOLD_COLOR,
    borderDash: [6, 4],
    borderWidth: 1.5,
    pointRadius: 0,
    pointHoverRadius: 4,
    fill: false,
    tension: 0,
    spanGaps: false,   // null in data breaks the line (e.g. 50k p99 ceiling)
    order: 1,          // draw above bars
    stepped: opts.stepped || false,
  };
}

// --- Vintage detection ---
const reportTimes = REPORTS
  .map(r => Date.parse(r.started_at))
  .filter(t => !Number.isNaN(t));
const minTime = reportTimes.length ? Math.min(...reportTimes) : 0;
const maxTime = reportTimes.length ? Math.max(...reportTimes) : 0;
const spanMs = maxTime - minTime;
const STALE_THRESHOLD_MS = 5 * 60 * 1000;  // 5 minutes

function fmtSpan(ms) {
  if (ms < 60_000) return Math.round(ms / 1000) + 's';
  const m = Math.round(ms / 60_000);
  if (m < 60) return m + 'm';
  const h = Math.floor(m / 60);
  return h + 'h ' + (m % 60) + 'm';
}
function fmtAgo(reportMs, refMs) {
  const delta = refMs - reportMs;
  if (delta < 60_000) return Math.round(delta / 1000) + 's ago';
  const m = Math.round(delta / 60_000);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m / 60);
  return h + 'h ' + (m % 60) + 'm ago';
}

// Banner if reports span > 5 minutes — likely a mix of runs.
if (spanMs > STALE_THRESHOLD_MS) {
  const minDate = new Date(minTime).toLocaleString();
  const maxDate = new Date(maxTime).toLocaleString();
  document.getElementById('vintageBanner').innerHTML = `
    <div class="banner">
      <strong>Mixed-vintage reports.</strong> The ${REPORTS.length} reports below span <strong>${fmtSpan(spanMs)}</strong>
      (oldest: ${minDate}, newest: ${maxDate}). Some are from earlier runs and may not reflect the
      current build. For a consistent comparison, delete <code>reports/*.json</code> and re-run the full
      matrix: <code>rm reports/*.json && bash scripts/stress-run.sh</code>.
    </div>
  `;
}

// --- Summary tiles ---
const passed = REPORTS.filter(r => r.verdict.pass).length;
const failed = REPORTS.length - passed;
const totalEvents = REPORTS.reduce((s, r) => s + (r.sent || 0), 0);
const totalLoss = REPORTS.reduce((s, r) => s + (r.missing || 0), 0);
const totalLossPct = totalEvents > 0 ? (totalLoss / totalEvents * 100) : 0;
const vintageClass = spanMs > STALE_THRESHOLD_MS ? 'fail' : '';
document.getElementById('summary').innerHTML = `
  <div class="stat"><div class="stat-value">${REPORTS.length}</div><div class="stat-label">runs</div></div>
  <div class="stat"><div class="stat-value pass">${passed}</div><div class="stat-label">passed</div></div>
  <div class="stat"><div class="stat-value ${failed > 0 ? 'fail' : ''}">${failed}</div><div class="stat-label">failed</div></div>
  <div class="stat"><div class="stat-value">${(totalEvents / 1e6).toFixed(2)}M</div><div class="stat-label">events sent</div></div>
  <div class="stat"><div class="stat-value ${totalLoss > 0 ? 'fail' : ''}">${totalLoss.toLocaleString()}</div><div class="stat-label">missing (${totalLossPct.toFixed(2)}%)</div></div>
  <div class="stat"><div class="stat-value ${vintageClass}">${reportTimes.length ? fmtSpan(spanMs) : '—'}</div><div class="stat-label">vintage span</div></div>
`;

// --- Rate chart (with per-tier rate-floor SLO line) ---
new Chart(document.getElementById('rateChart'), {
  type: 'bar',
  data: {
    labels: tiers.map(t => t.toLocaleString()),
    datasets: [
      ...bymode(r => +((r.rate_achieved / r.rate_target) * 100).toFixed(1)),
      thresholdDataset('rate floor SLO', t => {
        const slo = sloFor(t);
        return slo ? +(slo.rate_min_pct * 100).toFixed(1) : null;
      }, { stepped: true }),
    ],
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      tooltip: {
        callbacks: {
          label: ctx => {
            // Threshold line tooltip
            if (ctx.dataset.type === 'line') {
              return `rate floor SLO: ${ctx.parsed.y}%`;
            }
            const r = get(tiers[ctx.dataIndex], ctx.dataset.label);
            return `${ctx.dataset.label}: ${ctx.parsed.y}% (${r.rate_achieved.toFixed(0)}/${r.rate_target})`;
          },
        },
      },
    },
    scales: {
      y: { beginAtZero: true, max: 110, title: { display: true, text: '% of target rate' } },
      x: { title: { display: true, text: 'tier (msg/s)' } },
    },
  },
});

// --- Loss chart ---
new Chart(document.getElementById('lossChart'), {
  type: 'bar',
  data: {
    labels: tiers.map(t => t.toLocaleString()),
    datasets: bymode(r => +(r.missing_pct || 0).toFixed(2)),
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      tooltip: {
        callbacks: {
          label: ctx => {
            const r = get(tiers[ctx.dataIndex], ctx.dataset.label);
            return `${ctx.dataset.label}: ${ctx.parsed.y}% (${r.missing.toLocaleString()} of ${r.sent.toLocaleString()})`;
          },
        },
      },
    },
    scales: {
      y: { beginAtZero: true, title: { display: true, text: 'missing_pct (%)' } },
      x: { title: { display: true, text: 'tier (msg/s)' } },
    },
  },
});

// --- p99 chart (log scale, with per-tier ceiling line) ---
new Chart(document.getElementById('p99Chart'), {
  type: 'bar',
  data: {
    labels: tiers.map(t => t.toLocaleString()),
    datasets: [
      ...bymode(r => r.sync_latency_ms.p99),
      thresholdDataset('p99 ceiling SLO', t => {
        const slo = sloFor(t);
        // null ceiling (calibration mode, e.g. 50k) breaks the line at that point.
        return slo && slo.latency_p99_ms_max != null ? slo.latency_p99_ms_max : null;
      }, { stepped: true }),
    ],
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      tooltip: {
        callbacks: {
          label: ctx => {
            if (ctx.dataset.type === 'line') {
              return `p99 ceiling SLO: ${ctx.parsed.y}ms`;
            }
            const r = get(tiers[ctx.dataIndex], ctx.dataset.label);
            const ceiling = r.slo.latency_p99_ms_max;
            const v = ctx.parsed.y;
            const status = ceiling == null ? '(no ceiling)' : v <= ceiling ? `<= ${ceiling} OK` : `> ${ceiling} FAIL`;
            return `${ctx.dataset.label}: p99=${v}ms ${status}`;
          },
        },
      },
    },
    scales: {
      y: {
        type: 'logarithmic',
        title: { display: true, text: 'p99 sync-latency (ms, log scale)' },
        min: 1,
      },
      x: { title: { display: true, text: 'tier (msg/s)' } },
    },
  },
});

// --- Percentile distribution per tier+mode ---
const PERCENTILES = ['p50', 'p95', 'p99', 'p999', 'max'];
const PERCENTILE_LABELS = ['p50', 'p95', 'p99', 'p99.9', 'max'];
new Chart(document.getElementById('percentileChart'), {
  type: 'line',
  data: {
    labels: PERCENTILE_LABELS,
    datasets: REPORTS.map(r => ({
      label: `${r.tier.toLocaleString()} ${r.mode}`,
      data: PERCENTILES.map(p => r.sync_latency_ms[p]),
      borderColor: COLORS[r.mode],
      backgroundColor: COLORS[r.mode],
      borderDash: r.mode === 'single' ? [6, 4] : [],
      tension: 0.15,
      fill: false,
      borderWidth: 1.5,
      pointRadius: 3,
    })),
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    interaction: { mode: 'index', intersect: false },
    plugins: {
      tooltip: {
        callbacks: {
          label: ctx => `${ctx.dataset.label}: ${ctx.parsed.y}ms`,
        },
      },
      legend: { position: 'right', labels: { boxWidth: 16 } },
    },
    scales: {
      y: {
        type: 'logarithmic',
        title: { display: true, text: 'latency (ms, log scale)' },
        min: 1,
      },
    },
  },
});

// --- Full table ---
const tbody = document.querySelector('#reportTable tbody');
REPORTS.forEach(r => {
  const tr = document.createElement('tr');
  const ceiling = r.slo.latency_p99_ms_max;
  const reasons = [];
  if (!r.verdict.detail.rate_floor_ok) reasons.push('rate');
  if (!r.verdict.detail.missing_ok) reasons.push('missing');
  if (r.verdict.detail.p99_latency_ok === false) reasons.push('p99');
  const verdictHTML = r.verdict.pass
    ? '<span class="pass">PASS</span>'
    : `<span class="fail">FAIL</span><br><span class="muted">(${reasons.join(', ')})</span>`;
  const ratePct = (r.rate_achieved / r.rate_target * 100);
  const missingClass = r.missing > 0 ? 'fail' : '';
  const tMs = Date.parse(r.started_at);
  let ageHTML = '<span class="muted">—</span>';
  if (!Number.isNaN(tMs)) {
    const age = fmtAgo(tMs, GENERATED_AT_MS);
    // Mark stale if this report is more than 5 minutes older than the newest report.
    const isStale = (maxTime - tMs) > STALE_THRESHOLD_MS;
    ageHTML = `<span class="${isStale ? 'ago-stale' : 'muted'}" title="${new Date(tMs).toLocaleString()}">${age}</span>`;
  }
  tr.innerHTML = `
    <td>${r.tier.toLocaleString()}</td>
    <td class="mode-${r.mode}">${r.mode}</td>
    <td class="num">${r.rate_achieved.toFixed(0)} / ${r.rate_target.toLocaleString()}</td>
    <td class="num">${ratePct.toFixed(1)}%</td>
    <td class="num">${r.sent.toLocaleString()}</td>
    <td class="num">${r.received.toLocaleString()}</td>
    <td class="num ${missingClass}">${r.missing.toLocaleString()}</td>
    <td class="num ${missingClass}">${(r.missing_pct || 0).toFixed(2)}%</td>
    <td class="num">${r.trimmed.toLocaleString()}</td>
    <td class="num">${r.sync_latency_ms.p50}</td>
    <td class="num">${r.sync_latency_ms.p99}</td>
    <td class="num">${r.sync_latency_ms.p999}</td>
    <td class="num">${r.sync_latency_ms.max}</td>
    <td class="num ${ceiling == null ? 'muted' : ''}">${ceiling == null ? 'null' : ceiling}</td>
    <td>${verdictHTML}</td>
    <td class="num">${ageHTML}</td>
  `;
  tbody.appendChild(tr);
});
</script>
</body>
</html>
"""


def build_dashboard(reports):
    generated_at_ms = int(time.time() * 1000)
    return (
        HTML_TEMPLATE
        .replace("__DATA__", json.dumps(reports, separators=(",", ":")))
        .replace("__GENERATED_AT_MS__", str(generated_at_ms))
        .replace("__COUNT__", str(len(reports)))
    )


def main():
    if not REPORTS_DIR.is_dir():
        print(f"error: {REPORTS_DIR} does not exist", file=sys.stderr)
        return 1
    reports = load_reports()
    if not reports:
        print(f"error: no JSON reports found in {REPORTS_DIR}", file=sys.stderr)
        return 1
    html = build_dashboard(reports)
    out = REPORTS_DIR / "dashboard.html"
    out.write_text(html)
    print(f"Dashboard: {len(reports)} reports -> {out}")
    print(f"Open:      file://{out.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
