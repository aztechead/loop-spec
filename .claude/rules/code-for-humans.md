---
paths:
  - "lib/**"
  - "hooks/**"
  - "extensions/**"
  - "skills/**/*.{sh,js,ts,py}"
  - "agents/**"
  - "tests/**/*.{sh,js,py}"
---

# Code for humans

When you edit a file matching this rule's paths, Read `skills/shared/human-code.md`
before the first write. Do not paste that contract into a prompt.

Before you commit those files, run `bash lib/house-style.sh compare <files you touched>`,
`bash lib/comment-tells.sh scan <files>`, and `bash lib/failure-tells.sh scan <files>`
in the same turn. If a probe reports a finding, fix it or record a `simplicity:` marker
naming the ceiling. Never delete an existing `simplicity:` marker to make a probe pass.
