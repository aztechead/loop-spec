# Plain language

Use this contract for skill instructions, artifact prose, PR bodies, commit messages, and code comments.
Keep the meaning, conditions, scope, and requirement strength unchanged when simplifying text.
Preserve commands, identifiers, paths, numbers, quoted evidence, and machine-readable formats.

`lib/plain-language-lint.sh` reports readability candidates. It does not prove clarity or preserve meaning for you.
`lib/comment-tells.sh` separately checks comments that narrate changes, history, or adjacent code.

## STE-informed guidance

ASD owns ASD-STE100, the Simplified Technical English standard.
This repository does not reproduce its approved-word dictionary and makes **no claim of conformance**.
Describe this guidance as **STE-informed**, never **STE-compliant** or **STE-conformant**.

The [agent-writing adaptation](https://github.com/danyuchn/asd-ste100-skill) informs these structural rules:

- Use one instruction per sentence. Aim for at most 20 words per instruction and 25 per description.
- Name the actor and use active voice in instructions.
- Use simple tenses when they preserve meaning. Keep uncertainty such as "may have failed" when the evidence remains uncertain.
- Replace prose semicolons with separate sentences. Preserve semicolons in code and exact output.
- Prefer plain verbs over phrases such as "perform an analysis" or "carry out".
- Use one term for each concept. Keep necessary technical terms and define unfamiliar ones once.
- Avoid noun clusters longer than three words when a short phrase is clearer.
- Keep one topic per paragraph and at most six sentences.
- Use lists for three or more steps or conditions.
- Keep subjects, verbs, and articles. Do not shorten text into ambiguous fragments.

Apply these rules to instructions. Use the same sentence discipline for descriptions, with flexible vocabulary.
Keep longer wording when shortening it would lose a condition, exception, or other necessary precision.
Record that exception in the review. Do not claim dictionary compliance or certification.

## Orwell's six rules

The repository also follows these principles from Orwell's *Politics and the English Language*:

1. Avoid familiar figures of speech that add no meaning.
2. Prefer a short word when it means the same thing.
3. Remove words that add no information.
4. Prefer active voice.
5. Prefer everyday words over unnecessary jargon or foreign phrases.
6. Preserve sense when a style rule would make the text unclear.

Rule 6 is the escape hatch: the writer and reviewer must judge each suggestion in context.

## Readability checks

The linter uses eight heuristics. Its curated lists are local guidance, not ASD's dictionary.

| # | Rule | Machine check |
|---|---|---|
| 1 | Avoid stock phrases. | `stock-phrase` checks a curated list. |
| 2 | Prefer plain words. | `long-word` checks at least 20 substitution pairs. |
| 3 | Remove words that add nothing. | **No.** The reviewer must judge information value. |
| 4 | Prefer active voice. | `passive-voice` looks for a form of "be" followed by a past participle. |
| 5 | Avoid unnecessary foreign phrases and unexplained jargon. | `foreign-phrase` checks a curated phrase list. Jargon requires review. |
| 6 | Preserve sense over style. | **No, and never will be.** This requires judgment. |
| 7 | Keep one short instruction or thought per sentence. | `long-sentence` flags instructions over 20 words and descriptions over 25. |
| 8 | Write "and" or "or" explicitly when the choice matters. | `slash-and-or` checks listed pairs such as `and/or` and `pass/fail`. It excludes paths and version ranges. |
| 9 | Keep paragraphs short. | `long-paragraph` flags prose blocks over six sentences. |
| 10 | Use commands for procedural headings. | `gerund-heading` checks listed initial gerunds. Single-word noun headings such as "Testing" are allowed. |

Sentence structure, term consistency, scope preservation, and the other guidance above also require manual review.
The linter does not check all of them. A clean result proves only that its configured heuristics found no candidates.

## Run the linter

```text
plain-language-lint.sh prose    <file|-> [file...]
plain-language-lint.sh comments <file|-> [file...]
plain-language-lint.sh text     -
plain-language-lint.sh --rules
```

`prose` checks Markdown. It skips fenced code, table rows, URLs, inline code, and YAML frontmatter.
Link labels remain in scope.
`comments` extracts shell and Python `#` comments and Python triple-quoted docstrings with regexes.
`text` reads plain text, such as a PR body, from stdin. `--rules` lists check names.

The output contract matches `lib/artifact-lint.sh`:

```text
FLAG <path>:<line>: <check-name>: <detail>
plain-language-lint: ok (<mode>: <path>)
plain-language-lint: <n> flag(s) (<mode>: <path>)
```

Each finding produces one `FLAG` line. The final line reports either `ok` or the total flag count.
`--max-flags N` limits displayed findings, not the final count. A truncation line reports omitted findings.

Exit codes: 0 for clean input, 1 for findings or unreadable or empty input, and 2 for invalid invocation.

## Advisory only

This linter is not a phase gate. Never treat its non-zero exit as a hard failure in a skill, hook, or phase script.
Making it a gate requires a separate, reviewed change.
Treat findings as review suggestions, like `lib/house-style.sh probe` output.

## Known limitations

- The passive-voice check can flag adjectives such as "the plan is detailed" and miss passives without "be".
- Sentence splitting can misread abbreviations such as "e.g." or "i.e.".
- Every list item uses the 20-word instruction limit. Descriptive citations and decision entries can therefore produce false positives.
- Curated lists miss unlisted phrases. Necessary terms such as `implement`, `component`, and `requirement` are intentionally allowed.
- Tables, frontmatter, and code need separate review because `prose` mode skips them.
- Shortening every flagged sentence can remove meaning. Review the original and rewritten text together.

See `tests/lib/plain-language-lint.test.sh` for check behavior.
