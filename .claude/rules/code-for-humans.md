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

Read `skills/shared/human-code.md` before changing these files. Do not paste that
contract into a prompt.

Before DONE: `bash lib/house-style.sh compare <files you touched>`,
`bash lib/comment-tells.sh scan <files>`, `bash lib/failure-tells.sh scan <files>`.
Never cut `simplicity:` markers.
