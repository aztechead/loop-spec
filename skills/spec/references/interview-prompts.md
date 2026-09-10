# Intent questions for the SPEC author

Investigate the repository before presenting one consolidated list. Ask only about
choices that change the result the user sees and cannot be settled from evidence.

| Evidence leaves this open | Concrete question | Decision record must explain |
|---|---|---|
| Export is slow; no target is given | Which input size and latency must the export support? | The chosen bound and how it will be measured |
| Empty input has inconsistent handling | Should empty input return an empty result or an error? | The observable behavior and compatibility impact |
| Two existing storage conventions apply | Must data survive a restart? | The durability requirement; implementation details stay with the author |
| Scope crosses an adjacent command | Should that command change too? | The explicit boundary and why |

For greenfield work: Which input grows in production, and what bound must the first
release support? Investigate existing requirements before asking.

Each question includes a recommended answer and its consequence. Do not manufacture
rounds, personas, scores, or a transcript. Record answers in the decisions ledger.
When the list is empty, present the written Goal and Boundary for approval; autonomous
runs use the recorded recommendation contract in `skills/shared/autonomous-mode.md`.

A concrete approval call after the draft is written:

```javascript
AskUserQuestion({
  questions: [{
    question: "Do the Goal and Boundary in SPEC.md describe the requested result?",
    header: "Spec gate",
    options: [
      { label: "Approve", description: "Freeze these sections and proceed with implementation planning." },
      { label: "Revise", description: "Record the requested correction before approval." }
    ],
    multiSelect: false
  }]
})
```
