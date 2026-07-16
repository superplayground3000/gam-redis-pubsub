# Example Patterns for Friendly Documentation

Use these templates when a complicated code path or configuration needs an example file. Adapt the field names to the repository instead of copying placeholders blindly.

## Chart example: CDC forward/reverse sharding values

Place chart examples in `chart/examples/`. A good filename is explicit, for example `chart/examples/cdc-sharding-values.yaml`.

```yaml
# This example shows a multi-shard CDC setup for documentation and review.
# It is intentionally not production-ready until the placeholders, credentials,
# resource requests, and shard sizing are validated in the target environment.
cdcForward:
  enabled: true
  # shardCount controls how many independent forward workers consume source changes.
  # Keep this aligned with topic partitions or upstream routing capacity so a shard
  # does not sit idle or create uneven lag.
  shardCount: 4
  # routingKeyFields must be stable for the lifetime of the record. Changing them
  # can move the same logical entity between shards and may create duplicate work.
  routingKeyFields:
    - tenant_id
    - object_id
  consumerGroup: "cdc-forward-example"
  source:
    topic: "source-changes"
  destination:
    topic: "forwarded-changes"

cdcReverse:
  enabled: true
  # Use the same shardCount only when reverse traffic has similar throughput and
  # ordering requirements. Increase independently if reverse lag is consistently high.
  shardCount: 4
  routingKeyFields:
    - tenant_id
    - object_id
  consumerGroup: "cdc-reverse-example"
  source:
    topic: "reverse-source-changes"
  destination:
    topic: "reconciled-changes"
```

When documenting this example, explain:

- Why the selected shard count is safe for the sample but must be capacity-tested.
- How routing keys preserve ordering for related records.
- Which metrics indicate healthy behavior, such as consumer lag, retry count, and dead-letter count.
- Which scenarios are untested, such as changing shard count while traffic is active.
- Which improvements would reduce risk, such as startup validation for empty routing keys.

## Internal example: complicated Go/Python package behavior

Place examples for `internal/` code under a nearby `internal/examples/` folder. If the repository already has a clearer convention, follow the nearest established pattern while keeping the example inside `internal/examples/`.

```go
// This example demonstrates the happy path and the safest failure behavior.
// It uses placeholder inputs so it can be copied into tests or documentation
// without exposing environment-specific values.
package examples

func ExampleComplicatedFlow() {
    // Arrange realistic but safe input values.
    // Act through the public entry point rather than private helpers.
    // Assert or print the observable behavior that maintainers should expect.
}
```

Document next to the example:

- What behavior the example is intended to teach.
- Whether it is runnable as a test or only illustrative.
- Which edge cases still need dedicated tests.
- What future validation would make the behavior safer.

## Report template

Use this structure for implementation reports or review summaries:

```markdown
## Summary

Friendly overview of what changed and why it matters.

## Details

- Important design decision and rationale.
- Configuration or operational behavior.
- Error handling and fallback behavior.

## Testing

- Exact command or manual check.
- Result and any relevant limitation.

## Untested areas

- Area not tested, with the reason.
- Suggested staging or production-safe validation step.

## Potential improvements

- Concrete follow-up that would reduce risk, simplify maintenance, or improve observability.
```
