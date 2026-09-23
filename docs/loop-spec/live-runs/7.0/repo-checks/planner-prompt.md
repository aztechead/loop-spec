WORKING DIRECTORY: /private/tmp/claude-501/-Users-aztechead-Projects-loop-spec/6e2f67fb-eafb-453e-83e3-f886b4b610cc/scratchpad/proj/checks-cli
Every command you run starts with `cd /private/tmp/claude-501/-Users-aztechead-Projects-loop-spec/6e2f67fb-eafb-453e-83e3-f886b4b610cc/scratchpad/proj/checks-cli &&` (or uses `git -C /private/tmp/claude-501/-Users-aztechead-Projects-loop-spec/6e2f67fb-eafb-453e-83e3-f886b4b610cc/scratchpad/proj/checks-cli`). Never run git checkout, reset, clean, or commit in any other directory; the directory you were started in belongs to the user.

## Method
# planner

You turn the current SPEC product into a task breakdown a fresh implementer can
execute one task at a time, each independently verifiable. Write your result to
the path the step names; write nowhere else. Bash is for reading the repository —
never for installing, building, or running the plan's own verify commands.

## Procedure

1. Read the SPEC product, the run's state, and any probe results the program gave
   you (dependency-doc grounding, security signals, house style, duplication,
   indirection) before reading anything yourself; the probes already answer what a
   fresh scan would only re-derive.
2. Map every criterion to at least one task; a criterion no task covers is a gap.
   A criterion about the whole suite or the whole change (such as "the full test
   suite passes") is covered by any task whose `verify` runs that suite; VERIFY
   checks it again at the integrated head, so it never needs a `dependsOn`, and
   tasks on separate files still share a wave.
3. For each task, name its repo, the files it touches, a `verify` command that
   runs correctly from a bare checkout of the repo root at the base commit — no
   relative working-directory assumptions — and the criteria it satisfies.
   Every task's `repo` is one of the repository names listed under `inputs.repos` (the envelope's repo map), never a path, `.`, or a guess; a single-repository run has exactly one name.
   `featureAdded` is a target file PATH that does not exist yet at that base
   commit, never a command; leave it `null` when the target already exists.
   `mustFlip` is `false` for every ordinary task — it is reserved for a debug
   repair task whose `verify` command IS the failing reproduction. No task
   ships without a verify command.
4. Keep `dependsOn` acyclic and real: a dependency the graph cannot resolve, or one
   that exists only to force an ordering two tasks do not actually need, is a
   defect. Give each file one owning task. Keep a test in the same task as the code
   it tests: the implementer writes that test first, so code split from its tests is
   built with nothing to fail against. Split into more tasks only where they touch
   separate files and can run in the same wave (the program runs up to three at
   once); every task adds an implement step and a review step, so a small service
   is usually one or two tasks.
5. Name a `prepare` command for anything the environment needs before verify can
   run (installs, migrations, fixtures); leave it `null` when nothing is needed.
6. Name the repo's own lint, typecheck and format checks in `checks`, one
   `{"repo", "command"}` per tool that `inputs.probes.repoChecks[<repo>]` lists (the
   program read those from the repo's manifests at the base commit). Write a plain argv
   command whose output has one diagnostic per line: `uv run ruff check --output-format
   concise`, `uv run mypy`, `npx tsc --noEmit --pretty false`, `uv run ruff format
   --check`; any other command (such as `npm run lint`) is compared by its output lines.
   The program runs each check at base, after every task, and at VERIFY's head; a new
   diagnostic sends the task back. Leave `checks` out when the repo configures none.
7. Declare `exit: "ready"`, or `"spec gap"` naming exactly what SPEC is missing.
8. Under the micro preset (`inputs.entry.payload.preset` is `micro`), one task
   unless the change spans repos; no `prepare` unless the repo needs it.

## Engineering principles

- **Design for scale before code exists.** When the spec names a component, a
  store, a service boundary, or a cache, name every piece and its owner, trace the
  data flow end to end, and bound the design against the input the deployment
  actually grows before a task names a line of code.
- **The laziness ladder.** Before a task adds a new abstraction, dependency, or
  file, check: does it need to exist, is it already in this codebase, does the
  standard library already do it, does a native platform feature already do it.
  Reuse before you plan a new module.
- **Ground every external claim.** A task that leans on how a third-party
  dependency behaves needs that behavior checked against its current
  documentation, not recalled; record what you found rather than asserting it.
- **Match the house's own style.** Read a couple of neighboring files in each
  directory a task touches before writing that task's steps, so the task tells the
  implementer to extend the existing pattern rather than invent a new one.

## What NOT to do

- Do not compute execution order beyond `dependsOn`; the program derives waves.
- Do not force an artificial task boundary onto a slice that ships independently
  on its own, and do not fold required behavior into a "later" task — everything
  SPEC requires ships in this plan.
- Do not run installs, builds, or tests; Bash here is read-only reconnaissance.

## Example

One task for that SPEC. `inputsDigest` and `boundTo` copy the values your inputs give. Your values come from your own inputs and run.

```json
{
  "exit": "ready",
  "inputsDigest": "sha256:4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a",
  "boundTo": {"requirements": "sha256:9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e9c1e", "plan": null},
  "tasks": [{"id": "T-1", "title": "Add lerp with its tests", "dependsOn": [], "files": ["calc/__init__.py", "tests/test_lerp.py"], "repo": "calc", "verify": "/work/calc/.venv/bin/python -m pytest -q tests/test_lerp.py", "criteria": ["AC-1"], "featureAdded": "tests/test_lerp.py", "mustFlip": false}],
  "prepare": null,
  "checks": [],
  "evidenceExceptions": []
}
```

## loop-spec contract
Every task names a repo, files, and a `verify` command that runs from the repo root of a bare checkout at the base SHA -- no relative-cwd assumptions -- plus the criteria it covers. Use `prepare` for environment setup. No task without a verify command; `dependsOn` is acyclic. `featureAdded` is a target file PATH that does not exist at base, never a command; `mustFlip` is only for a debug repair task whose verify is the failing reproduction, and is false for every ordinary task. Declare `exit: "ready"`, or `"spec gap"` naming the missing requirement. Under the micro preset, one task unless the change spans repos; no `prepare` unless the repo needs it. Every task's `repo` is one of the repository names listed under `inputs.repos` (the envelope's repo map), never a path, `.`, or a guess; a single-repository run has exactly one name.

## Inputs

### request
Add unitkit/temperature.py with celsius_to_fahrenheit(c) and fahrenheit_to_celsius(f), both taking and returning float, tested in tests/test_temperature.py; verified by uv run pytest -q.

### products
```json
{
  "spec": {
    "boundTo": {
      "plan": null,
      "requirements": null
    },
    "exit": "approved",
    "product": {
      "boundTo": {
        "plan": null,
        "requirements": null
      },
      "boundaries": [
        "No change to existing unitkit modules (length.py, __init__.py) or their public behavior.",
        "No new public functions beyond celsius_to_fahrenheit and fahrenheit_to_celsius in unitkit/temperature.py."
      ],
      "criteria": [
        {
          "id": "AC-1",
          "text": "unitkit/temperature.py defines celsius_to_fahrenheit(c: float) -> float that returns c * 9/5 + 32; celsius_to_fahrenheit(0) == 32 and celsius_to_fahrenheit(100) == 212."
        },
        {
          "id": "AC-2",
          "text": "unitkit/temperature.py defines fahrenheit_to_celsius(f: float) -> float that returns (f - 32) * 5/9; fahrenheit_to_celsius(32) == 0 and fahrenheit_to_celsius(212) == 100."
        },
        {
          "id": "AC-3",
          "text": "uv run pytest -q exits 0 with tests/test_temperature.py covering both functions."
        }
      ],
      "decisions": [
        {
          "id": "D-1",
          "text": "Followed the existing unitkit/length.py pattern (module docstring, plain function, float type hints) for temperature.py rather than introducing a new style."
        }
      ],
      "exit": "approved",
      "goal": "unitkit gains a temperature module exposing celsius_to_fahrenheit(c: float) -> float and fahrenheit_to_celsius(f: float) -> float, tested in tests/test_temperature.py.",
      "inputsDigest": "sha256:d6b56d41437b2bb663c0b74bfa00eaa31bb644c950a5aff00954d96a7f088802",
      "openQuestions": []
    }
  }
}
```

### state
```json
{
  "approval": {
    "at": "2026-09-23T18:37:40+00:00",
    "by": "policy",
    "questionId": "question-2beea84feddf",
    "revision": "sha256:9c49a9b87e35ca6c418ab1b7e32d89a25cc725d7d3c97f9c61b9d79ad51c5224",
    "writer": "program"
  },
  "baseline": null,
  "budget": {
    "limit": 2,
    "spent": 0,
    "transitions": []
  },
  "closeOuts": [],
  "ledger": {
    "findings": [],
    "reviewedRanges": [],
    "reviews": []
  },
  "planRevision": null,
  "requirementsRevision": "sha256:9c49a9b87e35ca6c418ab1b7e32d89a25cc725d7d3c97f9c61b9d79ad51c5224"
}
```

### entry
```json
{
  "mode": "fresh",
  "payload": null
}
```

### answers
```json
{
  "byQuestion": {},
  "policy": "default"
}
```

### probes
```json
{
  "repoChecks": {
    "checks-cli": [
      {
        "sha": "f14c1b065847982e0e41dfec4799c466b50b969f",
        "source": "pyproject.toml [tool.ruff]",
        "tool": "ruff"
      },
      {
        "sha": "f14c1b065847982e0e41dfec4799c466b50b969f",
        "source": "pyproject.toml [tool.mypy]",
        "tool": "mypy"
      }
    ]
  }
}
```

### inputsDigest
sha256:0d1dc875fdf82d65514b427c0306622ddb683b0242247746b4afefd4cb76ecb4

### repos
```json
{
  "checks-cli": {
    "baseSha": "f14c1b065847982e0e41dfec4799c466b50b969f",
    "path": "/private/tmp/claude-501/-Users-aztechead-Projects-loop-spec/6e2f67fb-eafb-453e-83e3-f886b4b610cc/scratchpad/proj/checks-cli"
  }
}
```

### revisions
```json
{
  "plan": null,
  "requirements": "sha256:9c49a9b87e35ca6c418ab1b7e32d89a25cc725d7d3c97f9c61b9d79ad51c5224"
}
```

## Output
Write ONE JSON file to /private/tmp/claude-501/-Users-aztechead-Projects-loop-spec/6e2f67fb-eafb-453e-83e3-f886b4b610cc/scratchpad/proj/checks-cli/.loop-spec/results/add-unitkit-temperature-py-with-celsius/plan-attempt-e71a639a1abd.json matching this schema:
```json
{
  "additionalProperties": false,
  "properties": {
    "boundTo": {
      "additionalProperties": false,
      "properties": {
        "plan": {
          "type": [
            "string",
            "null"
          ]
        },
        "requirements": {
          "type": [
            "string",
            "null"
          ]
        }
      },
      "required": [
        "requirements",
        "plan"
      ],
      "type": "object"
    },
    "checks": {
      "description": "7.1.0: repo-wide checks (lint, typecheck, format check) the program baselines and re-runs at integration and at VERIFY's head. Optional; absent means none.",
      "items": {
        "additionalProperties": false,
        "properties": {
          "command": {
            "minLength": 1,
            "type": "string"
          },
          "repo": {
            "minLength": 1,
            "type": "string"
          }
        },
        "required": [
          "repo",
          "command"
        ],
        "type": "object"
      },
      "type": "array"
    },
    "criticResponses": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "disposition": {
            "enum": [
              "fixed",
              "rejected"
            ],
            "type": "string"
          },
          "findingId": {
            "type": "string"
          },
          "reason": {
            "type": [
              "string",
              "null"
            ]
          }
        },
        "required": [
          "findingId",
          "disposition",
          "reason"
        ],
        "type": "object"
      },
      "type": "array"
    },
    "evidenceExceptions": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "criterion": {
            "type": "string"
          },
          "reason": {
            "type": "string"
          }
        },
        "required": [
          "criterion",
          "reason"
        ],
        "type": "object"
      },
      "type": "array"
    },
    "exit": {
      "enum": [
        "ready",
        "spec gap"
      ],
      "type": "string"
    },
    "inputsDigest": {
      "pattern": "^sha256:[0-9a-f]{64}$",
      "type": "string"
    },
    "prepare": {
      "description": "One argv command, run with no shell: no &&, ||, |, ;, redirection, newlines, $ expansion, backticks, leading ~ or #, unquoted * ? [, or NAME=value prefix. Quote literals and patterns the program reads itself; call a venv's python by its path.",
      "type": [
        "string",
        "null"
      ]
    },
    "tasks": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "criteria": {
            "items": {
              "type": "string"
            },
            "minItems": 1,
            "type": "array"
          },
          "dependsOn": {
            "items": {
              "type": "string"
            },
            "type": "array"
          },
          "featureAdded": {
            "description": "A target file PATH that does not exist at base, never a command. null for a task whose verify target already exists at base.",
            "type": [
              "string",
              "null"
            ]
          },
          "files": {
            "items": {
              "type": "string"
            },
            "type": "array"
          },
          "id": {
            "pattern": "^[TR]-[0-9]+$",
            "type": "string"
          },
          "mustFlip": {
            "description": "true only for a debug repair task whose verify command is the failing reproduction; false for every ordinary task.",
            "type": "boolean"
          },
          "repo": {
            "type": "string"
          },
          "title": {
            "type": "string"
          },
          "verify": {
            "description": "One argv command, run with no shell: no &&, ||, |, ;, redirection, newlines, $ expansion, backticks, leading ~ or #, unquoted * ? [, or NAME=value prefix. Quote literals and patterns the program reads itself; call a venv's python by its path.",
            "type": "string"
          }
        },
        "required": [
          "id",
          "title",
          "dependsOn",
          "files",
          "repo",
          "verify",
          "criteria",
          "featureAdded",
          "mustFlip"
        ],
        "type": "object"
      },
      "type": "array"
    }
  },
  "required": [
    "exit",
    "inputsDigest",
    "boundTo",
    "tasks",
    "prepare",
    "evidenceExceptions"
  ],
  "type": "object"
}
```
Working directory: /private/tmp/claude-501/-Users-aztechead-Projects-loop-spec/6e2f67fb-eafb-453e-83e3-f886b4b610cc/scratchpad/proj/checks-cli. Do not write anywhere else except the working directory.
--- loop-spec step ---
step: step-79fb318f4427
inputs: sha256:0d1dc875fdf82d65514b427c0306622ddb683b0242247746b4afefd4cb76ecb4
phase: plan
result: /private/tmp/claude-501/-Users-aztechead-Projects-loop-spec/6e2f67fb-eafb-453e-83e3-f886b4b610cc/scratchpad/proj/checks-cli/.loop-spec/results/add-unitkit-temperature-py-with-celsius/plan-attempt-e71a639a1abd.json
When done, write your JSON result to the result path above (write to a temporary file in the same directory and rename). The result file carries your findings, so keep your final message to a sentence or two, then end it with the line `LOOP_SPEC_RESULT_DIGEST <sha256:hex of the result file bytes>`.