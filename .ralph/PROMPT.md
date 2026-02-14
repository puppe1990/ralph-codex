# Ralph Self-Improvement Runbook (Codex-First)

## Objective
Upgrade this repository itself to align with current Codex CLI capabilities while preserving backward compatibility and test stability.

## Hard constraints
- Work in small phases. Do not attempt all changes in one loop.
- Every phase must finish with:
  1. focused tests updated
  2. `npm test` passing
  3. one conventional commit
- Keep compatibility aliases where existing users may depend on old flags/vars.
- Do not remove legacy paths unless migration notes + tests are in place.

## Execution policy
- Prefer native Codex capabilities over Ralph-local heuristics when available.
- Preserve current behavior unless explicitly changed in fix_plan.md.
- If blocked, document blocker in `.ralph/docs/generated/blockers.md`.

## Required workflow per loop
1. Pick exactly one unchecked task from `.ralph/fix_plan.md` (highest priority first).
2. Implement minimal coherent change.
3. Update/add tests for that change.
4. Run `npm test`.
5. If green, mark task done and commit.
6. Append summary to `.ralph/docs/generated/self-improvement-log.md`.

## Technical priorities
- Add native Codex execution controls to `ralph_loop.sh` (sandbox/approval/profile/cwd/add-dir/ephemeral).
- Introduce structured output contract (`--output-schema` and/or `--output-last-message`) to reduce parsing ambiguity.
- Reduce session plumbing complexity by leveraging native resume behavior where possible.

## Out of scope for now
- Rewriting architecture in another language.
- Removing test suites unrelated to Codex migration.
- UI redesign.

## Done criteria
All high-priority tasks in `.ralph/fix_plan.md` are checked, tests pass, and docs (`README.md`, `TESTING.md`, `AGENTS.md`) reflect new behavior.
