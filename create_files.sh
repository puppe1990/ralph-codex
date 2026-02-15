#!/bin/bash

# Bootstrap Ralph files in an existing repository using Codex-ready templates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
RALPH_DIR=".ralph"
FORCE=false

usage() {
    cat <<'EOF'
Usage: ./create_files.sh [--force] [--help]

Creates/updates Ralph project files in the current repository:
  - .ralph/PROMPT.md
  - .ralph/fix_plan.md
  - .ralph/AGENT.md
  - .ralph/specs/*
  - .ralph/logs
  - .ralph/docs/generated

Options:
  --force   Overwrite existing template files
  --help    Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! -d "$TEMPLATES_DIR" ]]; then
    echo "Template directory not found: $TEMPLATES_DIR" >&2
    exit 1
fi

mkdir -p "$RALPH_DIR/specs" "$RALPH_DIR/logs" "$RALPH_DIR/docs/generated"

ensure_ralph_gitignore_entries() {
    local gitignore_file=".gitignore"
    local marker="# Ralph runtime artifacts"
    local entries=(
        ".ralph/"
        ".ralphrc"
        ".ralph/logs/"
        ".ralph/live.log"
        ".ralph/status.json"
        ".ralph/progress.json"
        ".ralph/.call_count"
        ".ralph/.last_reset"
        ".ralph/.exit_signals"
        ".ralph/.response_analysis"
        ".ralph/.json_parse_result"
        ".ralph/.loop_start_sha"
        ".ralph/.last_output_length"
        ".ralph/.circuit_breaker_state"
        ".ralph/.circuit_breaker_history"
        ".ralph/.codex_session_id"
        ".ralph/.ralph_session"
        ".ralph/.ralph_session_history"
    )

    [[ -f "$gitignore_file" ]] || : > "$gitignore_file"
    grep -qxF "$marker" "$gitignore_file" || printf '\n%s\n' "$marker" >> "$gitignore_file"

    local entry=""
    for entry in "${entries[@]}"; do
        grep -qxF "$entry" "$gitignore_file" || echo "$entry" >> "$gitignore_file"
    done
}

copy_template_file() {
    local src="$1"
    local dest="$2"

    if [[ -f "$dest" && "$FORCE" != "true" ]]; then
        echo "skip: $dest (already exists; use --force to overwrite)"
        return 0
    fi

    cp "$src" "$dest"
    echo "ok:   $dest"
}

copy_template_file "$TEMPLATES_DIR/PROMPT.md" "$RALPH_DIR/PROMPT.md"
copy_template_file "$TEMPLATES_DIR/fix_plan.md" "$RALPH_DIR/fix_plan.md"
copy_template_file "$TEMPLATES_DIR/AGENT.md" "$RALPH_DIR/AGENT.md"

if [[ -d "$TEMPLATES_DIR/specs" ]]; then
    if [[ "$FORCE" == "true" ]]; then
        rm -rf "$RALPH_DIR/specs"
    fi
    mkdir -p "$RALPH_DIR/specs"
    cp -R "$TEMPLATES_DIR/specs/." "$RALPH_DIR/specs/"
    echo "ok:   $RALPH_DIR/specs/"
fi

ensure_ralph_gitignore_entries
echo "ok:   .gitignore (Ralph runtime rules)"

echo
echo "Ralph files are ready in '$RALPH_DIR'."
echo "Next steps:"
echo "  1) Edit $RALPH_DIR/PROMPT.md with your current task"
echo "  2) Run ./ralph_loop.sh"
