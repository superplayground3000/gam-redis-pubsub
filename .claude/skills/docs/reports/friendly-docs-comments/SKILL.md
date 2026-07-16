---
name: friendly-docs-comments
description: Friendly, detailed technical writing standards for comments, documentation, reports, examples, and untested-area notes. Use when creating or editing code comments, README or docs content, changelogs, implementation reports, review summaries, YAML/config explanations, Helm chart documentation, Kubernetes examples, Prometheus/Istio notes, or example files for complicated code, chart values, internal packages, CDC reverse/forward sharding config, or other difficult-to-understand implementation details.
---

# Friendly Docs Comments

## Core writing style

Write in clear, friendly English that helps the next maintainer understand both the "what" and the "why".

- Prefer warm, direct phrasing: "This keeps...", "Use this when...", "The default is safe because...".
- Avoid blame, sarcasm, terse warnings, or unexplained jargon.
- Explain trade-offs, assumptions, constraints, fallback behavior, and operational impact.
- Keep comments close to the code or config they explain.
- Be detailed and verbose for documents, reports, examples, and known-risk sections.
- Keep inline comments easy to scan; move long narratives to block comments or documentation.
- Record potential improvements and untested areas whenever the work has known gaps, environment limits, or follow-up opportunities.

## Comment guidelines

Use comments to explain decisions that are not obvious from names, types, or structure.

- For simple code, use self-explanatory names instead of redundant comments.
- For complicated code, describe the intent, key invariants, error handling, and edge cases.
- For configuration or YAML, explain what a field controls, valid values when useful, safe defaults, and what can break if the value is wrong.
- For network, Kubernetes, Prometheus, Istio, or scaling behavior, document timeout, retry, cardinality, resource, routing, and failure-mode implications.
- For TODO-style notes, include the reason and a useful next action, not only a vague label.

Prefer this pattern for complex blocks:

```text
# Friendly summary of the behavior.
#
# Why this exists:
# - Reason or operational problem being solved.
#
# Important details:
# - Constraint, default, or edge case.
# - Failure mode or recovery expectation.
```

## Documentation and report guidelines

Documents and reports must be comprehensive enough that a new maintainer can act without reconstructing hidden context.

Include these sections when relevant:

1. Purpose and scope.
2. User-facing or operator-facing behavior.
3. Configuration reference with defaults and safe examples.
4. Design rationale and alternatives considered.
5. Operational notes: observability, rollout, rollback, and failure modes.
6. Testing performed, with exact commands when available.
7. Untested areas, environment limitations, and why they remain untested.
8. Potential improvements and follow-up work.

Use friendly phrasing such as:

- "This has not been tested in a live multi-shard deployment yet; verify it with a staging workload before production rollout."
- "A future improvement is to add validation that catches mismatched shard counts before the service starts."
- "This example intentionally keeps credentials as placeholders so it is safe to commit."

## Example-file placement rules

Create example files when a code path, YAML structure, or configuration is complicated enough that prose alone may be ambiguous.

- Put Helm chart and chart-related examples under `chart/examples/`.
- Put examples for code under `internal/` under the nearest useful `internal/examples/` folder.
- Keep example files committed only when they are safe: no real credentials, tokens, customer data, or environment-specific secrets.
- Prefer realistic placeholders and comments that show what users must replace.
- Add a short note in nearby documentation that points readers to the example file.
- If an example is intentionally not runnable, say so clearly in the file header and explain what must be changed.

For detailed templates and configuration examples, read `references/example-patterns.md`.

## Complex configuration expectations

When documenting complicated YAML or config, provide both prose and an example file. This is especially important for sharding and CDC-style settings such as `values.yaml` entries for `cdc-reverse` and `cdc-forward`.

Cover:

- The role of each major field.
- How fields relate to each other, such as shard count, routing key, source, destination, and consumer group naming.
- Safe defaults and production cautions.
- Validation or preflight checks that should exist.
- Observability signals that confirm the config is working.
- Untested combinations and recommended staging tests.

## Review checklist

Before finishing a task that uses this skill, verify:

- The wording is friendly, direct, and in English.
- Complicated parts have comments or documentation that explain intent and failure modes.
- Complicated config/code has an example file in the required location.
- Reports include testing, untested areas, and potential improvements.
- Comments do not restate obvious code and do not hide long design notes in tiny inline comments.
