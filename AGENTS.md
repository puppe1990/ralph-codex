# AGENTS.md

This document defines engineering guidance for AI/code agents working in this repository.

## Scope

- Project: Ralph for Codex CLI
- Runtime: Bash scripts with modular libraries in `/lib`
- Goal: autonomous development loop with safe exit detection, session continuity, and circuit breaker protections

## Primary Scripts

1. `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/ralph_loop.sh`: main loop runtime
2. `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/ralph_monitor.sh`: live monitor dashboard
3. `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/setup.sh`: new project bootstrap
4. `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/ralph_import.sh`: PRD/spec import and conversion
5. `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/ralph_enable.sh`: interactive enable wizard
6. `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/ralph_enable_ci.sh`: non-interactive enable flow
7. `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/create_files.sh`: lightweight template bootstrap for existing repos

## Libraries

- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/lib/response_analyzer.sh`: structured output analysis and completion signal extraction
- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/lib/circuit_breaker.sh`: CLOSED / HALF_OPEN / OPEN state machine and recovery
- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/lib/timeout_utils.sh`: cross-platform timeout wrapper
- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/lib/date_utils.sh`: portable time/date helpers
- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/lib/enable_core.sh`: shared logic for `ralph-enable*`
- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/lib/wizard_utils.sh`: prompt/selection utilities for interactive setup
- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/lib/task_sources.sh`: beads/GitHub/PRD task import

## Configuration Model

Canonical variables use `CODEX_*` names.
Legacy `CLAUDE_*` names are accepted as compatibility aliases in runtime scripts.

Important keys:

- `CODEX_CODE_CMD` (default: `codex`)
- `CODEX_TIMEOUT_MINUTES` (default: `15`)
- `CODEX_USE_CONTINUE` (default: `true`)
- `CODEX_SESSION_EXPIRY_HOURS` (default: `24`)
- `CODEX_MIN_VERSION` (default: `0.80.0`)
- `CODEX_OUTPUT_SCHEMA_FILE` (default: `.ralph/output_schema.json`, optional)

Compatibility no-op keys (kept only for older configs):

- `CODEX_OUTPUT_FORMAT`
- `CODEX_ALLOWED_TOOLS`

## Runtime Expectations

- Codex execution is JSON events (`--json`) and later normalized for analyzers.
- When supported by local Codex CLI, Ralph writes final model output via `--output-last-message` and uses it as preferred completion-analysis input (with JSONL fallback).
- Session continuity prefers `.ralph/.codex_session_id` and falls back to native `exec resume --last` when available.
- Circuit breaker opens on stagnation/repeated errors/permission-denial patterns.
- Permission failures should guide users to sandbox/approval configuration first.
- Real implementation progress is scoped to changes under `src/` or `tests/`; `.ralph/*` docs-only edits should not count as code progress.
- Enable/setup/bootstrap commands must update project `.gitignore` to hide Ralph runtime artifacts (logs, session/counter state, status/progress JSON files).

## Development Commands

```bash
# install local dependencies for tests
npm ci

# full test suite
npm test

# unit and integration split
npm run test:unit
npm run test:integration

# targeted execution
npm run test:file -- tests/unit/test_cli_modern.bats
npm run test:grep -- "session" tests/unit/test_cli_modern.bats
```

## Quality Bar

- Keep behavior backward-compatible unless intentionally breaking.
- Any runtime/CLI/config change should include tests.
- Prefer narrow, surgical edits over broad rewrites.
- Preserve `.ralph/` structure as the source of runtime state.

## Editing Rules

- Prefer `rg` for search and `bats` for script-level tests.
- Avoid destructive git operations.
- Do not remove compatibility aliases without migration notes and test updates.

## Documentation Sync

When changing user-facing behavior, update at least:

- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/README.md`
- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/CONTRIBUTING.md`
- `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/AGENTS.md`

## Global Install Sync

Whenever you change Ralph runtime/CLI behavior (for example `ralph_loop.sh`, `ralph_enable*`, `setup.sh`, files under `lib/`, or install wrappers), you must also:

1. Reinstall global commands with:
   - `/Users/matheuspuppe/Desktop/Projetos/github/ralph-codex/install.sh install`
2. Validate global command behavior from `~/.local/bin/ralph`/`~/.ralph/ralph_loop.sh` (at minimum `ralph --help` and newly added flags/options).

## Quick Checklist for Agent Changes

- [ ] Code changed minimally and coherently
- [ ] Tests added/updated
- [ ] `npm test` passing
- [ ] Docs updated if behavior changed
