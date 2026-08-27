---
paths:
  - "**/*.md"
  - "docs/**"
---

# Docs for humans

When you edit a file matching this rule's paths, Read `skills/shared/human-docs.md`
before the first write. Do not paste that contract into a prompt.

Before you commit that markdown, run `bash lib/doc-tells.sh scan <markdown you touched>`.
If the change makes another document false, edit that document in the same diff.
