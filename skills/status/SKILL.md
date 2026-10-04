---
name: status
description: "Shows where loop-spec runs stand in this repository: each run's phase, task graph, verify result, and PR. Use to check progress or find what a run is waiting on. It changes nothing."
argument-hint: "[slug]"
---

Run this and report what it prints:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" status [--slug "{slug}"]

Without `--slug` it lists the runs; with it, it shows one run in detail. To continue a
run, read `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` and follow the `next` line.
