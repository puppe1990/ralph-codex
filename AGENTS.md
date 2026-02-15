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
- `CODEX_AUTO_WAIT_ON_API_LIMIT` (default: `true`)
- `CODEX_API_LIMIT_WAIT_MINUTES` (default: `60`)
- `CODEX_LOG_PROGRESS` (default: `true`)
- `CODEX_PROGRESS_LOG_INTERVAL_SECONDS` (default: `30`)
- `DIAGNOSTIC_REPORT_MIN_INTERVAL_SECONDS` (default: `20`)
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
- Session continuity should prefer native `exec resume --last` (cwd-aware), then fall back to `.ralph/.codex_session_id`.
- Monitor mode should auto-close its tmux session when the main loop pane exits.
- Circuit breaker opens on stagnation/repeated errors/permission-denial patterns.
- API usage-limit pauses should auto-wait and retry by default (no interactive prompt).
- API usage-limit waits should prefer real reset epochs from Codex snapshot data (`5h_resets_at`) before fallback minutes.
- Permission failures should guide users to sandbox/approval configuration first.
- Known Codex state-db rollout warnings (`state db missing rollout path`, `state db record_discrepancy`) should be treated as non-fatal diagnostics.
- On startup, Ralph should reconcile stale orphaned runtime state by converting stale `running/paused/retrying` status to `stopped_unexpected` when no active process lock exists.
- Real implementation progress is scoped to changes under `src/` or `tests/`; `.ralph/*` docs-only edits should not count as code progress.
- Enable/setup/bootstrap commands must update project `.gitignore` to hide Ralph runtime artifacts (logs, session/counter state, status/progress JSON files).
- Status telemetry must include loop/timer fields consumed by monitor tooling: `current_loop`, `total_loops_executed`, `session_elapsed_seconds|hms`, and `loop_elapsed_seconds|hms`.
- Status telemetry must include canonical quota telemetry in `codex_quota_effective` (`source`, `five_hour`, `weekly`) to avoid UI/log parser divergence.
- Ralph should maintain consolidated diagnostics artifacts at `.ralph/diagnostics_latest.md` and `.ralph/diagnostics_latest.json` for troubleshooting/export.

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

# README badge sync
./scripts/update_readme_badges.sh --check
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
