---
unresolved_questions: []
footprint:
  - src/slugify.py
  - tests/test_slugify.py
---
# Strip dots in slugify

**Slug:** `strip-dots-in-slugify`

<!-- intent: frozen. The ask as SPEC understood it; ONESHOT, the reviewer, and the verifier read it as the goal and no later phase edits this block. -->
## Intent

`slugify("a.b")` returns `a.b`, so a title with a version number produces a slug the
router rejects. The change makes `slugify` drop dots the way it already drops spaces,
and nothing else about its output changes.
<!-- /intent -->

## Implementation notes

- src/slugify.py: `slugify()` (line 4) strips `.` in the same pass that replaces spaces.
- tests/test_slugify.py: one case for `a.b` next to the existing space case.
- The existing lower-casing and the hyphen join stay as they are.

## Success criteria

### Good Enough

- [ ] `python3 -c "from src.slugify import slugify; assert slugify('a.b') == 'ab'"` exits 0: dots are dropped
- [ ] `python3 -m pytest tests/test_slugify.py -q` exits 0: the existing cases still pass

## Grounding

- none
