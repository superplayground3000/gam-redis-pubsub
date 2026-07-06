#!/usr/bin/env python3
"""plot.py <run_dir>  — generate PNG charts + report.md from a run's CSVs ONLY.
Numbers are never hand-entered (DESIGN §0-5): every series is a column of the
scenario CSVs, rates are derived by differencing cumulative counters at plot time.
Runs inside python:3.12-slim (matplotlib + pandas)."""
import sys, os, json, glob
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RUN = sys.argv[1]
# target line comes from the run's report.json (written before plotting); default 5000.
TARGET = 5000
try:
    _rj = json.load(open(os.path.join(RUN, "report.json")))
    TARGET = int(_rj.get("target", TARGET))
except Exception:
    pass
PREFIX_COLS = ["apply_a", "apply_b", "apply_c", "apply_d"]
PEND_COLS = ["pending_a", "pending_b", "pending_c", "pending_d"]
ACKP_COLS = ["ackp_a", "ackp_b", "ackp_c", "ackp_d"]


def num(s):
    return pd.to_numeric(s, errors="coerce")


def load(csv):
    df = pd.read_csv(csv)
    df["t"] = num(df["ts_epoch"])
    df["t"] = df["t"] - df["t"].min()
    for c in PREFIX_COLS + PEND_COLS + ACKP_COLS + ["writer_sent", "writer_rate_target",
                                                    "p50_ms", "p95_ms", "p99_ms", "unproc_total", "source_lag"]:
        if c in df:
            df[c] = num(df[c])
    return df


def rate(series, t):
    """per-sample rate of a cumulative counter (delta/dt)."""
    d = series.diff()
    dt = t.diff()
    return (d / dt).clip(lower=0)


def steady(df):
    """steady-state aggregate apply rate = median per-sample aggregate rate over 2nd half."""
    t = df["t"]
    agg = sum(rate(df[c].fillna(0), t) for c in PREFIX_COLS if c in df)
    half = agg[len(agg) // 2:]
    return float(half.median()) if len(half) else 0.0


def plot_throughput(df, name, out):
    t = df["t"]
    fig, ax = plt.subplots(figsize=(9, 4.5))
    agg = None
    for c in PREFIX_COLS:
        if c in df and df[c].fillna(0).max() > 0:
            r = rate(df[c].fillna(0), t)
            ax.plot(t, r, lw=1, alpha=0.7, label=f"apply {c[-1]}")
            agg = r if agg is None else agg + r
    if agg is not None:
        ax.plot(t, agg, lw=2.4, color="black", label="aggregate apply")
    if "writer_sent" in df:
        ax.plot(t, rate(df["writer_sent"].fillna(0), t), lw=1.2, ls="--", color="tab:blue", label="writer sent")
    if "writer_rate_target" in df and df["writer_rate_target"].notna().any():
        ax.plot(t, df["writer_rate_target"], lw=1, ls=":", color="gray", label="writer target")
    ax.axhline(TARGET, color="red", ls="--", lw=1, label=f"{TARGET} target")
    ax.set_title(f"{name} — throughput (msg/s)")
    ax.set_xlabel("time in measurement window (s)")
    ax.set_ylabel("msg/s")
    ax.set_ylim(bottom=0)
    ax.legend(fontsize=7, ncol=2)
    ax.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(out, dpi=110); plt.close(fig)


def plot_backlog(df, name, out):
    t = df["t"]
    fig, ax = plt.subplots(figsize=(9, 4.5))
    for c in PEND_COLS:
        if c in df and df[c].fillna(0).max() > 0:
            ax.plot(t, df[c], lw=1.2, label=f"pending {c[-1]}")
    for c in ACKP_COLS:
        if c in df and df[c].fillna(0).max() > 0:
            ax.plot(t, df[c], lw=1, ls="--", alpha=0.7, label=f"ack_pending {c[-1]}")
    ax.set_title(f"{name} — consumer backlog (num_pending / num_ack_pending)")
    ax.set_xlabel("time in measurement window (s)")
    ax.set_ylabel("messages")
    ax.set_ylim(bottom=0)
    ax.legend(fontsize=7, ncol=2); ax.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(out, dpi=110); plt.close(fig)


def plot_latency(df, name, out):
    t = df["t"]
    if not any(c in df and df[c].notna().any() for c in ["p50_ms", "p95_ms", "p99_ms"]):
        return False
    fig, ax = plt.subplots(figsize=(9, 4.5))
    for c, lab in [("p50_ms", "p50"), ("p95_ms", "p95"), ("p99_ms", "p99")]:
        if c in df and df[c].notna().any():
            ax.plot(t, df[c], lw=1.4, label=lab)
    ax.set_title(f"{name} — end-to-end latency (ms)")
    ax.set_xlabel("time in measurement window (s)")
    ax.set_ylabel("ms")
    ax.set_yscale("log")
    ax.legend(fontsize=8); ax.grid(alpha=0.3, which="both")
    fig.tight_layout(); fig.savefig(out, dpi=110); plt.close(fig)
    return True


def main():
    csvs = sorted(glob.glob(os.path.join(RUN, "S*.csv")))
    results = {}
    for csv in csvs:
        name = os.path.splitext(os.path.basename(csv))[0]
        try:
            df = load(csv)
        except Exception as e:
            print(f"skip {name}: {e}"); continue
        if len(df) < 2:
            print(f"skip {name}: too few rows"); continue
        st = steady(df)
        results[name] = st
        plot_throughput(df, name, os.path.join(RUN, f"{name}_throughput.png"))
        plot_backlog(df, name, os.path.join(RUN, f"{name}_backlog.png"))
        plot_latency(df, name, os.path.join(RUN, f"{name}_latency.png"))
        print(f"{name}: steady aggregate = {st:.0f} msg/s")

    # comparison bar
    if results:
        fig, ax = plt.subplots(figsize=(8, 4.5))
        names = list(results.keys())
        vals = [results[n] for n in names]
        colors = ["tab:green" if v >= TARGET else "tab:orange" for v in vals]
        ax.bar(names, vals, color=colors)
        ax.axhline(TARGET, color="red", ls="--", lw=1.2, label=f"{TARGET} target")
        for i, v in enumerate(vals):
            ax.text(i, v, f"{v:.0f}", ha="center", va="bottom", fontsize=8)
        ax.set_title("Steady-state aggregate apply throughput by scenario")
        ax.set_ylabel("msg/s (median, 2nd half of window)")
        ax.legend(fontsize=8); ax.grid(alpha=0.3, axis="y")
        fig.tight_layout(); fig.savefig(os.path.join(RUN, "comparison.png"), dpi=110); plt.close(fig)

    # report.md
    rj = {}
    rjp = os.path.join(RUN, "report.json")
    if os.path.exists(rjp):
        try:
            rj = json.load(open(rjp))
        except Exception:
            rj = {}
    scen = {s["name"]: s for s in rj.get("scenarios", []) if isinstance(s, dict)}
    lines = []
    lines.append(f"# by-key-prefix-split-topic — run {rj.get('ts','?')}\n")
    lines.append(f"- Delay injected: **{rj.get('toxic_ms','?')} ms** each direction (toxiproxy), target line **{TARGET} msg/s**.")
    lines.append(f"- Harness sound (S0 ≥ target): **{bool(rj.get('harness_ok'))}** · a split config held ≥ target under delay: **{bool(rj.get('any_split_pass'))}** · correctness (unproc/parity) ok: **{bool(rj.get('c4_ok'))}**\n")
    lines.append("## Scenario summary\n")
    lines.append("| Scenario | prefixes(N) | delay | maxAckPending | rate | measured agg (msg/s) | p95 (ms) | verdict |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for n in sorted(results.keys()):
        s = scen.get(n, {})
        N = len(str(s.get("prefixes", "")).split(",")) if s.get("prefixes") else "?"
        lines.append(f"| {n} | {N} | {s.get('toxic','?')} | {s.get('max_ack_pending','?')} | {s.get('rate','?')} | {results[n]:.0f} | {s.get('p95_ms','?')} | {s.get('verdict','?')} |")
    lines.append("\n## Charts\n")
    lines.append("![comparison](comparison.png)\n")
    for n in sorted(results.keys()):
        lines.append(f"### {n}\n")
        lines.append(f"![{n} throughput]({n}_throughput.png)\n")
        lines.append(f"![{n} backlog]({n}_backlog.png)\n")
        if os.path.exists(os.path.join(RUN, f"{n}_latency.png")):
            lines.append(f"![{n} latency]({n}_latency.png)\n")
    lines.append("\n## Hypotheses (DESIGN §6) vs measured\n")
    s1 = results.get("S1"); s4 = results.get("S4"); s2 = results.get("S2")
    if s1 is not None:
        lines.append(f"- **H1 (single-sink in-flight ceiling):** S1 measured **{s1:.0f} msg/s** at maxAckPending=1024 under delay "
                     f"(predicted 2500–5500; {'consistent' if s1 < TARGET else 'ABOVE target — unexpected'}).")
    if s1 is not None and s4 is not None:
        lines.append(f"- **H2 (horizontal split ≈ N× window):** S4 (N=4) measured **{s4:.0f} msg/s** vs S1 **{s1:.0f}** "
                     f"(ratio {s4/max(s1,1):.1f}×; {'≥target' if s4>=TARGET else '<target'}).")
    if s2 is not None:
        lines.append(f"- **H3 (vertical tuning):** S2 (maxAckPending=8192, single sink) measured **{s2:.0f} msg/s** "
                     f"({'also ≥target — tuning alone suffices' if s2>=TARGET else 'still <target'}).")
    open(os.path.join(RUN, "report.md"), "w").write("\n".join(lines) + "\n")
    print("wrote report.md")


if __name__ == "__main__":
    main()
