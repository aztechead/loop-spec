# Routing accepted code-review findings

For the VERIFY or ONESHOT author: judge each finding at its cited line, then group
findings by root cause. A false verdict still requires a disproof. An accepted
finding carries a `routing` JSON object after its evidence:

```text
- src/a.py:12 — endpoint excluded | verdict: true — reproduced by test_range | routing: {"route":"patch","cause":"range endpoint","surface":"none","fixCommit":"1a2b3c4"}
```

Choose the route from the root cause:

| Route | Required JSON fields beyond `route` and `cause` | Driver action |
|---|---|---|
| `intent-gap` | `section`: Goal, Boundary, or Intent; `question`: concrete human decision | Revert implementation and publish an escalation naming the decision. Autonomous runs stop with that condition. |
| `bad-spec` | `section`: existing section outside frozen intent; `replacement`: corrected section body | Revert implementation, amend that section with a change-log entry, and return through DISCUSS and PLAN on the full route, or repeat ONESHOT. |
| `patch` | `surface`: `none`; `fixCommit`: commit SHA | Verify the fix is on the reviewed branch and changes at most ten lines in one text file. It cannot edit this build's spec. |
| `defer` | `reason`: evidence for leaving this work to a separate change | Add an idempotent backlog entry containing the finding and reason. |

A public interface change cannot be called a patch merely because its diff is short.
Do not patch over incorrect intent or an incorrect spec. The driver refuses recovery
over dirty implementation files, preserves the spec and review evidence when reverting
code, and caps recovery at five attempts. Matching root causes must have matching routes.
An intent-gap ends this build. Record the human's clarified intent in a new build;
the original approval remains immutable for audit.

For the driver-written ONESHOT record, pass this object through
`verification verdict --finding FILE:LINE --verdict true --reason EVIDENCE --routing JSON`.
The false path needs only the finding, verdict, and disproof reason.
