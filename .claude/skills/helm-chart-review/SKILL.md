---
name: helm-chart-review
description: >-
  Review, audit, or sanity-check a Helm chart in this repository and its
  values.yaml parameters. Renders the chart with `helm template` to see what
  will actually be deployed and tested, then gives precise, prioritized,
  severity-rated feedback on the parameters — which values are well-chosen,
  which are risky or wrong for the intended purpose, and exactly how to fix
  them. Use this skill WHENEVER the user asks anything like: "review / audit /
  look over this Helm chart or values.yaml", "are these chart parameters good /
  safe / sane / production-ready?", "I changed some values (resources, replicas,
  persistence, limits) — are they right?", "give me feedback on my values.yaml",
  "sanity-check the chart before I helm install", "what will this chart actually
  deploy?", or "suggest better values". Trigger even when the request looks
  simple, mentions only "values"/"parameters"/"chart" without the word "review",
  or names a specific chart (e.g. the rrcs / redis-redpanda chart under labs/):
  the skill adds a render-and-verify pass and a purpose-scoping step that a quick
  read of the values would miss, so always consult it for chart/values
  assessment instead of answering from the templates directly. Do NOT use it for
  authoring a brand-new chart, deploying or installing a release, debugging a
  running pod or a failing stress run, mechanical edits like version bumps,
  chart-to-kustomize migration, or non-Helm reviews (Dockerfiles, container
  images).
---

# Helm Chart Review

## What this does and why

A Helm chart's `values.yaml` is a pile of knobs. Reading the knobs alone tells
you what is *configurable*, not what is *deployed* — defaults, conditionals,
helpers, and `tpl` expansion all sit between the values and the real manifests.
And a value is never good or bad in the abstract: `persistence.mode: emptyDir`
is the right call for a throwaway throughput lab and a data-loss bug in
production; one replica is fine for a dev cluster and an outage waiting to
happen in prod.

So this skill does three things, in order:

1. **Establishes the yardstick** — confirms what the deployment is *for* before
   judging anything.
2. **Renders reality** — runs `helm template` so the review is grounded in the
   manifests that will actually apply, not in a guess about what the values do.
3. **Reports precisely** — gives per-parameter, severity-rated findings tied to
   the stated purpose, with concrete fixes.

Work through the steps in order. Don't skip the scope step — it's what makes the
rest of the review correct instead of generic.

## Step 0 — Locate the chart

Find the chart(s) in the repo:

```bash
find . -name Chart.yaml -not -path '*/node_modules/*' -not -path '*/.git/*'
```

- One chart → use it.
- Several → list them and ask the user which one to review (or whether to review
  all). Don't assume.

Note the chart directory (the folder containing `Chart.yaml`) and any sibling
values files (`values*.yaml`, `*values*.example`) — those are the configurations
you may need to render.

## Step 1 — Establish scope FIRST (always ask)

Before rendering or analyzing, confirm the intent. Ask the user a short batch of
questions and **wait for the answers**. Use the `AskUserQuestion` tool if
available; otherwise ask in plain text. Cover:

1. **Purpose** — what is this deployment for? (local dev lab, CI, load/stress
   test, staging, production service, demo…)
2. **Target environment** — where does it run? (kind/minikube/single-node vs a
   real multi-node cluster; ephemeral vs long-lived; is data expected to
   survive restarts?)
3. **Which configuration** — which values file(s), profile, or mode should the
   review assume? (e.g. default `values.yaml`, a `values-dev.yaml`, an external
   `-f` override, a `profile`/`mode` selector). If the chart gates optional
   workloads behind a flag, ask whether to include them.
4. **Focus** (optional) — anything to weight: correctness, security, cost/
   resource sizing, reliability/HA, upgrade safety.

Why this is non-negotiable: every verdict below ("good", "risky", "bad") is
measured against these answers. Reviewing without them produces vague,
context-free advice that's often wrong for the user's real situation. If the
user has already stated the purpose clearly in the conversation, reflect it back
in one line to confirm rather than re-asking from scratch.

Record the confirmed scope — it becomes the first section of the report.

## Step 2 — Render what will actually be deployed

Render the chart for the confirmed scope. Capture output so you can read it.

```bash
CHART=<chart-dir>
OUT=$(mktemp -d)

# Base render (default values)
helm template rrcs "$CHART" > "$OUT/base.yaml" 2> "$OUT/base.err" \
  || echo "RENDER FAILED — see $OUT/base.err"

# Each relevant values file / override the user named
helm template rrcs "$CHART" -f "$CHART/values-dev.yaml" > "$OUT/dev.yaml" 2>&1

# Selector knobs (profiles, modes, external vs bundled) the user cares about
helm template rrcs "$CHART" --set someProfile=alo > "$OUT/profile-alo.yaml" 2>&1

# Optional workloads gated behind a flag (test/harness jobs, etc.)
helm template rrcs "$CHART" -s templates/<gated-job>.yaml --set <gate>=true > "$OUT/gated.yaml" 2>&1
```

Also run a quick structural sanity pass:

```bash
helm lint "$CHART"
helm template rrcs "$CHART" | grep -nE '^(kind|  name):' | head -50   # quick inventory
```

Rules:

- **A render error is the top finding.** If `helm template` fails (bad
  templating, a required value, an over-budget name guard), report that first —
  nothing else matters until it renders.
- **Be exhaustive — render every permutation that could behave differently**,
  not just defaults: each profile/mode selector, bundled vs external, and every
  gated/optional workload. A knob you didn't render is a knob you're reviewing
  blind. If the user named a specific config ("production with external Redis"),
  render *that* too, but don't stop there.
- **Verify every claim by re-rendering.** Don't assert "an invalid value
  silently renders an empty config" — prove it with `helm template --set
  key=bogus` and read the output. Don't assert "external mode drops the bundled
  Redis" — render it and confirm. A review grounded in a render you actually ran
  is worth far more than one reasoned from reading templates.
- **Render gated/optional workloads too** when they're in scope. A chart that
  deploys a service *and* a test/stress Job both deploys and "tests" — describe
  both.
- Read the rendered YAML. Verify that a knob actually changes the manifest. A
  values key that renders into nothing (typo'd, unreferenced, or silently
  swallowed by an `else` branch) is itself a finding.

## Step 3 — Analyze parameters against the purpose

Go through `values.yaml` parameter by parameter, checking each rendered effect
against the confirmed purpose. For every knob, decide: is this value
appropriate *for what this deployment is for*? Useful dimensions to sweep:

- **Image refs** — pinned to immutable tags vs floating (`:dev`, `:latest`)?
  `pullPolicy` sane for the target cluster? Registry/pull-secrets wired through?
- **Resources** — are `requests`/`limits` set and proportional to the workload?
  Limits that throttle a load test, or requests too low to schedule reliably?
  Don't forget `ephemeral-storage` requests/limits for workloads writing to
  `emptyDir`/local disk (JetStream file store, scratch dirs) — without them a
  busy pod can fill the node.
- **Runtime vs cgroup limits** — does each process's *runtime* concurrency match
  its CPU limit? This is the foot-gun a plain requests/limits read misses. A Go
  binary without `automaxprocs` sets `GOMAXPROCS` to the *node's* core count, not
  the cgroup limit, so a 2-core-limited pod on a 16-core node spins up 16 Ps and
  thrashes the scheduler the moment it's throttled — inflating CPU and distorting
  any latency/throughput the workload is meant to measure. Same class: JVM
  `-XX:ActiveProcessorCount`, Node's `UV_THREADPOOL_SIZE`, OMP threads. The chart
  is where you inject the matching env var. For a benchmarking/load workload this
  is a correctness issue, not a nit, because it silently skews the numbers.
- **Replicas / HA** — single replica where the purpose implies availability?
  Anti-affinity / PDB absent for a prod service?
- **Persistence & data durability** — `emptyDir` vs PVC; size; storageClass.
  Right for ephemeral, wrong for stateful prod.
- **Security posture** — runs as root? `securityContext`, `automountService
  AccountToken`, secrets in plain env vs mounted Secrets, capability drops.
- **Networking & exposure** — Service types, ports, anything exposed wider than
  intended.
- **Health & lifecycle** — liveness/readiness probes present? graceful drains?
- **Parameter consistency** — does an override fully propagate? A knob that
  updates one manifest but leaves a hardcoded path/value elsewhere is
  misleading and a real bug.
- **Validation gaps** — free-form values where a typo silently falls through to
  a wrong default (e.g. an enum-by-convention that defaults via `else`), or a
  bad value that renders cleanly and only fails at runtime.
- **Upgrade safety** — immutable fields (Job selectors, hash-named resources)
  that a value change would break on `helm upgrade`.
- **Naming / labels** — prefix/length budgets, missing standard
  `app.kubernetes.io/*` labels.

For each parameter, land on a verdict and, when it's not "good", a concrete
better value or change — not "consider tuning this" but "set X to Y because Z".

## Step 4 — Write the report

Use this structure exactly. Lead with scope so every finding is anchored to it.
Severity is relative to the **stated purpose**, not to an absolute ideal.

```markdown
# Helm Chart Review: <chart name> (<Chart.yaml version>)

## Scope (confirmed)
- **Purpose:** <one line>
- **Target environment:** <one line>
- **Configuration reviewed:** <values files / profile / mode / gated workloads>

## What will be deployed
<Inventory from the rendered manifests: each workload (kind, name, replicas),
key Services/ConfigMaps/Secrets/Jobs/PVCs, and — if a test/harness workload is
in scope — what it exercises. A short list or table, grounded in the render.>

## Findings

### 🔴 Critical — breaks the deployment or causes data loss / exposure for this purpose
- `param.path` (values.yaml:LN) — current: `value`
  Why it matters here: <reason tied to the purpose>
  **Fix:** <concrete change>

### 🟠 High — likely to cause real problems; fix before relying on it
- …

### 🟡 Medium — suboptimal; fix when convenient
- …

### 🔵 Low / nit — minor polish
- …

### 🟢 Well-chosen — good calls worth keeping (call these out explicitly)
- `param.path` — <why it's right for this purpose>

## Priority summary
1. <highest-impact action>
2. …
```

Guidance on the report:

- **Cite precisely.** Reference `values.yaml` line numbers and the rendered
  manifest you're reacting to. Vague findings ("resources could be better") are
  not useful; "writer.limits.cpu is 2 but MAX_RATE=20000 will saturate one core
  — raise to 4 or drop MAX_RATE" is.
- **Severity is purpose-relative.** Say so when a value is fine for the stated
  purpose but would be Critical elsewhere — that teaches the boundary.
- **Always include the 🟢 section.** A review that's only complaints hides
  whether the author got the important things right and erodes trust in the
  prioritization.
- **End with the priority summary** so the user knows what to do first.

## Notes

- If `helm` isn't installed, say so and stop — this skill depends on real
  rendering, not on eyeballing templates.
- Keep the analysis grounded in the render. If you find yourself reviewing a
  value without having confirmed what it renders to, go back to Step 2.
