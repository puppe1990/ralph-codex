# Ralph Fix Plan - Self Improvement (Codex CLI Alignment)

## High Priority
- [x] Add CLI passthrough/config support in `ralph_loop.sh` for Codex native controls: `--sandbox`, `--full-auto`, `--dangerously-bypass-approvals-and-sandbox`, `--profile`, `--cd`, `--add-dir`, `--skip-git-repo-check`, `--ephemeral`.
- [x] Add tests for new Codex native controls in `tests/unit/test_cli_parsing.bats` and `tests/unit/test_cli_modern.bats`.
- [x] Implement structured completion output path (prefer `--output-last-message` and optional `--output-schema`) and integrate with `lib/response_analyzer.sh`.
- [x] Add regression tests proving structured output path works and fallback path still works.

## Medium Priority
- [x] Introduce native resume mode strategy using `codex resume --last` where applicable; keep compatibility fallback to session-file flow.
- [x] Refactor and remove no-op/self-assignment code in `ralph_loop.sh` argument parsing and compatibility sync.
- [ ] Add docs section in `README.md` with recommended Codex security profiles (`read-only`, `workspace-write`, `danger-full-access`) and approval policy examples.

## Low Priority
- [ ] Add optional `.ralphrc` keys that map to Codex profile/sandbox defaults (without breaking existing configs).
- [ ] Add a lightweight diagnostics command/output for effective Codex runtime configuration (active sandbox/profile/timeout).
- [ ] Expand CI checks to detect reintroduction of deprecated legacy naming in active docs.

## Completed
- [x] Migrate docs from `CLAUDE.md` to `AGENTS.md`.
- [x] Standardize core naming to `CODEX_*` with compatibility aliases.
- [x] Modernize `create_files.sh` scaffold for Codex-first projects.
- [x] Add CI guard against active `CLAUDE.md` references.

## Notes
- Keep each commit scoped to one task or one tightly coupled test+code unit.
- If a task requires large changes, split into subtasks before coding.
