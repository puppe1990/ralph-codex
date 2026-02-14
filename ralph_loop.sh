#!/bin/bash

# Codex CLI Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Codex CLI with usage management

set -e  # Exit on any error

# Note: CLAUDE_CODE_ENABLE_DANGEROUS_PERMISSIONS_IN_SANDBOX and IS_SANDBOX
# environment variables are NOT exported here. Tool restrictions are handled
# via --allowedTools flag in CODEX_CMD_ARGS, which is the proper approach.
# Exporting sandbox variables without a verified sandbox would be misleading.

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/timeout_utils.sh"
source "$SCRIPT_DIR/lib/response_analyzer.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"

# Configuration
# Ralph-specific files live in .ralph/ subfolder
RALPH_DIR=".ralph"
PROMPT_FILE="$RALPH_DIR/PROMPT.md"
LOG_DIR="$RALPH_DIR/logs"
DOCS_DIR="$RALPH_DIR/docs/generated"
STATUS_FILE="$RALPH_DIR/status.json"
PROGRESS_FILE="$RALPH_DIR/progress.json"
LOCK_DIR="$RALPH_DIR/.lock"
CODEX_CODE_CMD="${CODEX_CODE_CMD:-${CLAUDE_CODE_CMD:-codex}}"
SLEEP_DURATION=3600     # 1 hour in seconds
LIVE_OUTPUT=false       # Show Codex CLI output in real-time (streaming)
LIVE_LOG_FILE="$RALPH_DIR/live.log"  # Fixed file for live output monitoring
CALL_COUNT_FILE="$RALPH_DIR/.call_count"
TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
USE_TMUX=false
CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE:-}"
CODEX_PROFILE="${CODEX_PROFILE:-}"
CODEX_CWD="${CODEX_CWD:-}"
CODEX_ADD_DIRS="${CODEX_ADD_DIRS:-}"  # Comma-separated list
CODEX_SKIP_GIT_REPO_CHECK="${CODEX_SKIP_GIT_REPO_CHECK:-false}"
CODEX_EPHEMERAL="${CODEX_EPHEMERAL:-false}"
CODEX_FULL_AUTO="${CODEX_FULL_AUTO:-false}"
CODEX_DANGEROUS_BYPASS="${CODEX_DANGEROUS_BYPASS:-false}"
CODEX_OUTPUT_SCHEMA_FILE="${CODEX_OUTPUT_SCHEMA_FILE:-$RALPH_DIR/output_schema.json}"

# Runtime capability detection (populated by detect_codex_structured_output_capabilities)
CODEX_SUPPORTS_OUTPUT_LAST_MESSAGE=false
CODEX_SUPPORTS_OUTPUT_SCHEMA=false
CODEX_LAST_MESSAGE_FILE=""

# Save environment variable state BEFORE setting defaults
# These are used by load_ralphrc() to determine which values came from environment
_env_MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-}"
_env_CODEX_TIMEOUT_MINUTES="${CODEX_TIMEOUT_MINUTES:-${CLAUDE_TIMEOUT_MINUTES:-}}"
_env_CODEX_OUTPUT_FORMAT="${CODEX_OUTPUT_FORMAT:-${CLAUDE_OUTPUT_FORMAT:-}}"
_env_CODEX_ALLOWED_TOOLS="${CODEX_ALLOWED_TOOLS:-${CLAUDE_ALLOWED_TOOLS:-}}"
_env_CODEX_USE_CONTINUE="${CODEX_USE_CONTINUE:-${CLAUDE_USE_CONTINUE:-}}"
_env_CODEX_SESSION_EXPIRY_HOURS="${CODEX_SESSION_EXPIRY_HOURS:-${CLAUDE_SESSION_EXPIRY_HOURS:-}}"
_env_CODEX_MIN_VERSION="${CODEX_MIN_VERSION:-${CLAUDE_MIN_VERSION:-}}"
_env_CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE:-}"
_env_CODEX_PROFILE="${CODEX_PROFILE:-}"
_env_CODEX_CWD="${CODEX_CWD:-}"
_env_CODEX_ADD_DIRS="${CODEX_ADD_DIRS:-}"
_env_CODEX_SKIP_GIT_REPO_CHECK="${CODEX_SKIP_GIT_REPO_CHECK:-}"
_env_CODEX_EPHEMERAL="${CODEX_EPHEMERAL:-}"
_env_CODEX_FULL_AUTO="${CODEX_FULL_AUTO:-}"
_env_CODEX_DANGEROUS_BYPASS="${CODEX_DANGEROUS_BYPASS:-}"
_env_CODEX_OUTPUT_SCHEMA_FILE="${CODEX_OUTPUT_SCHEMA_FILE:-}"
_env_VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-}"
_env_CB_COOLDOWN_MINUTES="${CB_COOLDOWN_MINUTES:-}"
_env_CB_AUTO_RESET="${CB_AUTO_RESET:-}"

# Now set defaults (only if not already set by environment)
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-100}"
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
CODEX_TIMEOUT_MINUTES="${CODEX_TIMEOUT_MINUTES:-${CLAUDE_TIMEOUT_MINUTES:-15}}"

# Modern Codex CLI configuration (Phase 1.1)
CODEX_OUTPUT_FORMAT="${CODEX_OUTPUT_FORMAT:-${CLAUDE_OUTPUT_FORMAT:-json}}"
CODEX_ALLOWED_TOOLS="${CODEX_ALLOWED_TOOLS:-${CLAUDE_ALLOWED_TOOLS:-Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)}}"
CODEX_USE_CONTINUE="${CODEX_USE_CONTINUE:-${CLAUDE_USE_CONTINUE:-true}}"
CODEX_SESSION_FILE="${CODEX_SESSION_FILE:-${CLAUDE_SESSION_FILE:-$RALPH_DIR/.codex_session_id}}" # Session ID persistence file
CODEX_MIN_VERSION="${CODEX_MIN_VERSION:-${CLAUDE_MIN_VERSION:-0.80.0}}"  # Minimum recommended Codex CLI version

# Session management configuration (Phase 1.2)
# Note: SESSION_EXPIRATION_SECONDS is defined in lib/response_analyzer.sh (86400 = 24 hours)
RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"              # Ralph-specific session tracking (lifecycle)
RALPH_SESSION_HISTORY_FILE="$RALPH_DIR/.ralph_session_history"  # Session transition history
# Session expiration: 24 hours default balances project continuity with fresh context
# Too short = frequent context loss; Too long = stale context causes unpredictable behavior
CODEX_SESSION_EXPIRY_HOURS=${CODEX_SESSION_EXPIRY_HOURS:-${CLAUDE_SESSION_EXPIRY_HOURS:-24}}

# Legacy variable aliases (backward compatibility)
CLAUDE_CODE_CMD="$CODEX_CODE_CMD"
CLAUDE_TIMEOUT_MINUTES="$CODEX_TIMEOUT_MINUTES"
CLAUDE_OUTPUT_FORMAT="$CODEX_OUTPUT_FORMAT"
CLAUDE_ALLOWED_TOOLS="$CODEX_ALLOWED_TOOLS"
CLAUDE_USE_CONTINUE="$CODEX_USE_CONTINUE"
CLAUDE_SESSION_FILE="$CODEX_SESSION_FILE"
CLAUDE_MIN_VERSION="$CODEX_MIN_VERSION"
CLAUDE_SESSION_EXPIRY_HOURS="$CODEX_SESSION_EXPIRY_HOURS"

# Valid tool patterns for --allowed-tools validation
# Tools can be exact matches or pattern matches with wildcards in parentheses
VALID_TOOL_PATTERNS=(
    "Write"
    "Read"
    "Edit"
    "MultiEdit"
    "Glob"
    "Grep"
    "Task"
    "TodoWrite"
    "WebFetch"
    "WebSearch"
    "Bash"
    "Bash(git *)"
    "Bash(npm *)"
    "Bash(bats *)"
    "Bash(python *)"
    "Bash(node *)"
    "NotebookEdit"
)

# Exit detection configuration
EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30  # If more than 30% of recent loops are test-only, flag it

# .ralphrc configuration file
RALPHRC_FILE=".ralphrc"
RALPHRC_LOADED=false

# load_ralphrc - Load project-specific configuration from .ralphrc
#
# This function sources .ralphrc if it exists, applying project-specific
# settings. Environment variables take precedence over .ralphrc values.
#
# Configuration values that can be overridden:
#   - MAX_CALLS_PER_HOUR
#   - CODEX_TIMEOUT_MINUTES (legacy: CLAUDE_TIMEOUT_MINUTES)
#   - CODEX_OUTPUT_FORMAT (legacy: CLAUDE_OUTPUT_FORMAT)
#   - CODEX_ALLOWED_TOOLS / ALLOWED_TOOLS (deprecated no-op in Codex mode)
#   - SESSION_CONTINUITY (mapped to CODEX_USE_CONTINUE)
#   - SESSION_EXPIRY_HOURS (mapped to CODEX_SESSION_EXPIRY_HOURS)
#   - CODEX_SANDBOX_MODE / SANDBOX_MODE
#   - CODEX_PROFILE
#   - CODEX_CWD
#   - CODEX_ADD_DIRS
#   - CODEX_SKIP_GIT_REPO_CHECK
#   - CODEX_EPHEMERAL
#   - CODEX_FULL_AUTO
#   - CODEX_DANGEROUS_BYPASS
#   - CODEX_OUTPUT_SCHEMA_FILE
#   - CB_NO_PROGRESS_THRESHOLD
#   - CB_SAME_ERROR_THRESHOLD
#   - CB_OUTPUT_DECLINE_THRESHOLD
#   - RALPH_VERBOSE
#
load_ralphrc() {
    if [[ ! -f "$RALPHRC_FILE" ]]; then
        return 0
    fi

    # Source .ralphrc (this may override default values)
    # shellcheck source=/dev/null
    source "$RALPHRC_FILE"

    # Map .ralphrc variable names to internal names
    if [[ -n "${CODEX_ALLOWED_TOOLS:-}" ]]; then
        CODEX_ALLOWED_TOOLS="$CODEX_ALLOWED_TOOLS"
    fi
    if [[ -n "${ALLOWED_TOOLS:-}" ]]; then
        CODEX_ALLOWED_TOOLS="$ALLOWED_TOOLS"
    fi
    if [[ -n "${SESSION_CONTINUITY:-}" ]]; then
        CODEX_USE_CONTINUE="$SESSION_CONTINUITY"
    fi
    if [[ -n "${SESSION_EXPIRY_HOURS:-}" ]]; then
        CODEX_SESSION_EXPIRY_HOURS="$SESSION_EXPIRY_HOURS"
    fi
    if [[ -n "${CODEX_TIMEOUT_MINUTES:-}" ]]; then
        CODEX_TIMEOUT_MINUTES="$CODEX_TIMEOUT_MINUTES"
    fi
    if [[ -n "${CLAUDE_TIMEOUT_MINUTES:-}" ]]; then
        CODEX_TIMEOUT_MINUTES="$CLAUDE_TIMEOUT_MINUTES"
    fi
    if [[ -n "${CODEX_OUTPUT_FORMAT:-}" ]]; then
        CODEX_OUTPUT_FORMAT="$CODEX_OUTPUT_FORMAT"
    fi
    if [[ -n "${CLAUDE_OUTPUT_FORMAT:-}" ]]; then
        CODEX_OUTPUT_FORMAT="$CLAUDE_OUTPUT_FORMAT"
    fi
    if [[ -n "${CODEX_MIN_VERSION:-}" ]]; then
        CODEX_MIN_VERSION="$CODEX_MIN_VERSION"
    fi
    if [[ -n "${CLAUDE_MIN_VERSION:-}" ]]; then
        CODEX_MIN_VERSION="$CLAUDE_MIN_VERSION"
    fi
    if [[ -n "${RALPH_VERBOSE:-}" ]]; then
        VERBOSE_PROGRESS="$RALPH_VERBOSE"
    fi
    if [[ -n "${CODEX_SANDBOX_MODE:-}" ]]; then
        CODEX_SANDBOX_MODE="$CODEX_SANDBOX_MODE"
    fi
    if [[ -n "${SANDBOX_MODE:-}" ]]; then
        CODEX_SANDBOX_MODE="$SANDBOX_MODE"
    fi
    if [[ -n "${CODEX_PROFILE:-}" ]]; then
        CODEX_PROFILE="$CODEX_PROFILE"
    fi
    if [[ -n "${CODEX_CWD:-}" ]]; then
        CODEX_CWD="$CODEX_CWD"
    fi
    if [[ -n "${CODEX_ADD_DIRS:-}" ]]; then
        CODEX_ADD_DIRS="$CODEX_ADD_DIRS"
    fi
    if [[ -n "${CODEX_SKIP_GIT_REPO_CHECK:-}" ]]; then
        CODEX_SKIP_GIT_REPO_CHECK="$CODEX_SKIP_GIT_REPO_CHECK"
    fi
    if [[ -n "${CODEX_EPHEMERAL:-}" ]]; then
        CODEX_EPHEMERAL="$CODEX_EPHEMERAL"
    fi
    if [[ -n "${CODEX_FULL_AUTO:-}" ]]; then
        CODEX_FULL_AUTO="$CODEX_FULL_AUTO"
    fi
    if [[ -n "${CODEX_DANGEROUS_BYPASS:-}" ]]; then
        CODEX_DANGEROUS_BYPASS="$CODEX_DANGEROUS_BYPASS"
    fi
    if [[ -n "${CODEX_OUTPUT_SCHEMA_FILE:-}" ]]; then
        CODEX_OUTPUT_SCHEMA_FILE="$CODEX_OUTPUT_SCHEMA_FILE"
    fi

    # Restore ONLY values that were explicitly set via environment variables
    # (not script defaults). The _env_* variables were captured BEFORE defaults were set.
    # If _env_* is non-empty, the user explicitly set it in their environment.
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_CODEX_TIMEOUT_MINUTES" ]] && CODEX_TIMEOUT_MINUTES="$_env_CODEX_TIMEOUT_MINUTES"
    [[ -n "$_env_CODEX_OUTPUT_FORMAT" ]] && CODEX_OUTPUT_FORMAT="$_env_CODEX_OUTPUT_FORMAT"
    [[ -n "$_env_CODEX_ALLOWED_TOOLS" ]] && CODEX_ALLOWED_TOOLS="$_env_CODEX_ALLOWED_TOOLS"
    [[ -n "$_env_CODEX_USE_CONTINUE" ]] && CODEX_USE_CONTINUE="$_env_CODEX_USE_CONTINUE"
    [[ -n "$_env_CODEX_SESSION_EXPIRY_HOURS" ]] && CODEX_SESSION_EXPIRY_HOURS="$_env_CODEX_SESSION_EXPIRY_HOURS"
    [[ -n "$_env_CODEX_MIN_VERSION" ]] && CODEX_MIN_VERSION="$_env_CODEX_MIN_VERSION"
    [[ -n "$_env_CODEX_SANDBOX_MODE" ]] && CODEX_SANDBOX_MODE="$_env_CODEX_SANDBOX_MODE"
    [[ -n "$_env_CODEX_PROFILE" ]] && CODEX_PROFILE="$_env_CODEX_PROFILE"
    [[ -n "$_env_CODEX_CWD" ]] && CODEX_CWD="$_env_CODEX_CWD"
    [[ -n "$_env_CODEX_ADD_DIRS" ]] && CODEX_ADD_DIRS="$_env_CODEX_ADD_DIRS"
    [[ -n "$_env_CODEX_SKIP_GIT_REPO_CHECK" ]] && CODEX_SKIP_GIT_REPO_CHECK="$_env_CODEX_SKIP_GIT_REPO_CHECK"
    [[ -n "$_env_CODEX_EPHEMERAL" ]] && CODEX_EPHEMERAL="$_env_CODEX_EPHEMERAL"
    [[ -n "$_env_CODEX_FULL_AUTO" ]] && CODEX_FULL_AUTO="$_env_CODEX_FULL_AUTO"
    [[ -n "$_env_CODEX_DANGEROUS_BYPASS" ]] && CODEX_DANGEROUS_BYPASS="$_env_CODEX_DANGEROUS_BYPASS"
    [[ -n "$_env_CODEX_OUTPUT_SCHEMA_FILE" ]] && CODEX_OUTPUT_SCHEMA_FILE="$_env_CODEX_OUTPUT_SCHEMA_FILE"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"

    # Keep legacy variable names synced for backward compatibility.
    CLAUDE_CODE_CMD="$CODEX_CODE_CMD"
    CLAUDE_TIMEOUT_MINUTES="$CODEX_TIMEOUT_MINUTES"
    CLAUDE_OUTPUT_FORMAT="$CODEX_OUTPUT_FORMAT"
    CLAUDE_ALLOWED_TOOLS="$CODEX_ALLOWED_TOOLS"
    CLAUDE_USE_CONTINUE="$CODEX_USE_CONTINUE"
    CLAUDE_SESSION_FILE="$CODEX_SESSION_FILE"
    CLAUDE_MIN_VERSION="$CODEX_MIN_VERSION"
    CLAUDE_SESSION_EXPIRY_HOURS="$CODEX_SESSION_EXPIRY_HOURS"

    RALPHRC_LOADED=true
    return 0
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Initialize directories
mkdir -p "$LOG_DIR" "$DOCS_DIR"

# Single-instance lock state
LOCK_ACQUIRED=false

# Acquire a per-project lock to prevent concurrent loops from corrupting state files.
acquire_instance_lock() {
    local pid_file="$LOCK_DIR/pid"

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$pid_file"
        LOCK_ACQUIRED=true
        return 0
    fi

    # Lock exists: check whether owner is still running.
    local existing_pid=""
    if [[ -f "$pid_file" ]]; then
        existing_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    fi

    if [[ -n "$existing_pid" && "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
        log_status "ERROR" "Another Ralph loop is already running in this project (PID $existing_pid)."
        log_status "INFO" "Use 'ralph --status' or stop the running process before starting a new one."
        return 1
    fi

    # Stale lock: recover.
    rm -f "$pid_file" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$pid_file"
        LOCK_ACQUIRED=true
        log_status "WARN" "Recovered stale Ralph lock."
        return 0
    fi

    log_status "ERROR" "Could not acquire project lock: $LOCK_DIR"
    return 1
}

release_instance_lock() {
    if [[ "$LOCK_ACQUIRED" != "true" ]]; then
        return 0
    fi

    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_ACQUIRED=false
}

# Check if tmux is available
check_tmux_available() {
    if ! command -v tmux &> /dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        echo "  CentOS/RHEL: sudo yum install tmux"
        exit 1
    fi
}

# Get the tmux base-index for windows (handles custom tmux configurations)
# Returns: the base window index (typically 0 or 1)
get_tmux_base_index() {
    local base_index
    base_index=$(tmux show-options -gv base-index 2>/dev/null)
    # Default to 0 if not set or tmux command fails
    echo "${base_index:-0}"
}

# Setup tmux session with monitor
setup_tmux_session() {
    local session_name="ralph-$(date +%s)"
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local project_dir="$(pwd)"

    # Get the tmux base-index to handle custom configurations (e.g., base-index 1)
    local base_win
    base_win=$(get_tmux_base_index)

    log_status "INFO" "Setting up tmux session: $session_name"

    # Initialize live.log file
    echo "=== Ralph Live Output - Waiting for first loop... ===" > "$LIVE_LOG_FILE"

    # Create new tmux session detached (left pane - Ralph loop)
    tmux new-session -d -s "$session_name" -c "$project_dir"

    # Split window vertically (right side)
    tmux split-window -h -t "$session_name" -c "$project_dir"

    # Split right pane horizontally (top: Codex output, bottom: status)
    tmux split-window -v -t "$session_name:${base_win}.1" -c "$project_dir"

    # Right-top pane (pane 1): Live Codex CLI output
    tmux send-keys -t "$session_name:${base_win}.1" "tail -f '$project_dir/$LIVE_LOG_FILE'" Enter

    # Right-bottom pane (pane 2): Ralph status monitor
    if command -v ralph-monitor &> /dev/null; then
        tmux send-keys -t "$session_name:${base_win}.2" "ralph-monitor" Enter
    else
        tmux send-keys -t "$session_name:${base_win}.2" "'$ralph_home/ralph_monitor.sh'" Enter
    fi

    # Start ralph loop in the left pane (exclude tmux flag to avoid recursion)
    # Forward all CLI parameters that were set by the user
    local ralph_cmd
    if command -v ralph &> /dev/null; then
        ralph_cmd="ralph"
    else
        ralph_cmd="'$ralph_home/ralph_loop.sh'"
    fi

    # Always use --live mode in tmux for real-time streaming
    ralph_cmd="$ralph_cmd --live"

    # Forward --calls if non-default
    if [[ "$MAX_CALLS_PER_HOUR" != "100" ]]; then
        ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    # Forward --prompt if non-default
    if [[ "$PROMPT_FILE" != "$RALPH_DIR/PROMPT.md" ]]; then
        ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    fi
    # Forward --verbose if enabled
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        ralph_cmd="$ralph_cmd --verbose"
    fi
    # Forward --timeout if non-default (default is 15)
    if [[ "$CODEX_TIMEOUT_MINUTES" != "15" ]]; then
        ralph_cmd="$ralph_cmd --timeout $CODEX_TIMEOUT_MINUTES"
    fi
    # Forward --no-continue if session continuity disabled
    if [[ "$CODEX_USE_CONTINUE" == "false" ]]; then
        ralph_cmd="$ralph_cmd --no-continue"
    fi
    # Forward --session-expiry if non-default (default is 24)
    if [[ "$CODEX_SESSION_EXPIRY_HOURS" != "24" ]]; then
        ralph_cmd="$ralph_cmd --session-expiry $CODEX_SESSION_EXPIRY_HOURS"
    fi
    # Forward --auto-reset-circuit if enabled
    if [[ "$CB_AUTO_RESET" == "true" ]]; then
        ralph_cmd="$ralph_cmd --auto-reset-circuit"
    fi
    if [[ -n "$CODEX_SANDBOX_MODE" ]]; then
        ralph_cmd="$ralph_cmd --sandbox $CODEX_SANDBOX_MODE"
    fi
    if [[ "$CODEX_FULL_AUTO" == "true" ]]; then
        ralph_cmd="$ralph_cmd --full-auto"
    fi
    if [[ "$CODEX_DANGEROUS_BYPASS" == "true" ]]; then
        ralph_cmd="$ralph_cmd --dangerously-bypass-approvals-and-sandbox"
    fi
    if [[ -n "$CODEX_PROFILE" ]]; then
        ralph_cmd="$ralph_cmd --profile '$CODEX_PROFILE'"
    fi
    if [[ -n "$CODEX_CWD" ]]; then
        ralph_cmd="$ralph_cmd --cd '$CODEX_CWD'"
    fi
    if [[ -n "$CODEX_ADD_DIRS" ]]; then
        local IFS=','
        read -ra add_dirs_tmux <<< "$CODEX_ADD_DIRS"
        local add_dir_tmux
        for add_dir_tmux in "${add_dirs_tmux[@]}"; do
            add_dir_tmux=$(echo "$add_dir_tmux" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$add_dir_tmux" ]]; then
                ralph_cmd="$ralph_cmd --add-dir '$add_dir_tmux'"
            fi
        done
    fi
    if [[ "$CODEX_SKIP_GIT_REPO_CHECK" == "true" ]]; then
        ralph_cmd="$ralph_cmd --skip-git-repo-check"
    fi
    if [[ "$CODEX_EPHEMERAL" == "true" ]]; then
        ralph_cmd="$ralph_cmd --ephemeral"
    fi

    tmux send-keys -t "$session_name:${base_win}.0" "$ralph_cmd" Enter

    # Focus on left pane (main ralph loop)
    tmux select-pane -t "$session_name:${base_win}.0"

    # Set pane titles (requires tmux 2.6+)
    tmux select-pane -t "$session_name:${base_win}.0" -T "Ralph Loop"
    tmux select-pane -t "$session_name:${base_win}.1" -T "Codex Output"
    tmux select-pane -t "$session_name:${base_win}.2" -T "Status"

    # Set window title
    tmux rename-window -t "$session_name:${base_win}" "Ralph: Loop | Output | Status"

    log_status "SUCCESS" "Tmux session created with 3 panes:"
    log_status "INFO" "  Left:         Ralph loop"
    log_status "INFO" "  Right-top:    Codex CLI live output"
    log_status "INFO" "  Right-bottom: Status monitor"
    log_status "INFO" ""
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"

    # Attach to session (this will block until session ends)
    tmux attach-session -t "$session_name"

    exit 0
}

# Initialize call tracking
init_call_tracking() {
    # Debug logging removed for cleaner output
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    # Reset counter if it's a new hour
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    # Initialize exit signals tracking if it doesn't exist
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    # Initialize circuit breaker
    init_circuit_breaker

}

# Log function with timestamps and colors
log_status() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac
    
    # Write to stderr so log messages don't interfere with function return values
    echo -e "${color}[$timestamp] [$level] $message${NC}" >&2
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log"
}

# Update status JSON for external monitoring
update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}
    
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# Check if we can make another call
can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call
    else
        return 0  # Can make call
    fi
}

# Increment call counter
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Wait for rate limit reset with countdown
wait_for_reset() {
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    log_status "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."
    
    # Calculate time until next hour
    local current_minute=$(date +%M)
    local current_second=$(date +%S)
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))
    
    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."
    
    # Countdown display
    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))
        
        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"
    
    # Reset counter
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
should_exit_gracefully() {
    
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        return 1  # Don't exit, file doesn't exist
    fi
    
    local signals=$(cat "$EXIT_SIGNALS_FILE")
    
    # Count recent signals (last 5 loops) - with error handling
    local recent_test_loops
    local recent_done_signals  
    local recent_completion_indicators
    
    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")
    

    # Check for exit conditions

    # 0. Permission denials (highest priority - Issue #101)
    # When Codex CLI is denied permission to run commands, halt immediately
    # to allow user to update Codex approval/sandbox configuration
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local has_permission_denials=$(jq -r '.analysis.has_permission_denials // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
        if [[ "$has_permission_denials" == "true" ]]; then
            local denied_count=$(jq -r '.analysis.permission_denial_count // 0' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "0")
            local denied_cmds=$(jq -r '.analysis.denied_commands | join(", ")' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "unknown")
            log_status "WARN" "🚫 Permission denied for $denied_count command(s): $denied_cmds"
            log_status "WARN" "Review Codex approval/sandbox policy configuration before retrying"
            echo "permission_denied"
            return 0
        fi
    fi

    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        log_status "WARN" "Exit condition: Too many test-focused loops ($recent_test_loops >= $MAX_CONSECUTIVE_TEST_LOOPS)"
        echo "test_saturation"
        return 0
    fi
    
    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        log_status "WARN" "Exit condition: Multiple completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)"
        echo "completion_signals"
        return 0
    fi
    
    # 3. Safety circuit breaker - force exit after 5 consecutive EXIT_SIGNAL=true responses
    # Note: completion_indicators only accumulates when Codex CLI explicitly sets EXIT_SIGNAL=true
    # (not based on confidence score). This safety breaker catches cases where the agent signals
    # completion 5+ times but the normal exit path (completion_indicators >= 2 + EXIT_SIGNAL=true)
    # didn't trigger for some reason. Threshold of 5 prevents API waste while being higher than
    # the normal threshold (2) to avoid false positives.
    if [[ $recent_completion_indicators -ge 5 ]]; then
        log_status "WARN" "🚨 SAFETY CIRCUIT BREAKER: Force exit after 5 consecutive EXIT_SIGNAL=true responses ($recent_completion_indicators)" >&2
        echo "safety_circuit_breaker"
        return 0
    fi

    # 4. Strong completion indicators (only if Codex CLI's EXIT_SIGNAL is true)
    # This prevents premature exits when heuristics detect completion patterns
    # but Codex CLI explicitly indicates work is still in progress via RALPH_STATUS block.
    # The exit_signal in .response_analysis represents explicit agent intent.
    local claude_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        claude_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators) with EXIT_SIGNAL=true" >&2
        echo "project_complete"
        return 0
    fi
    
    # 5. Check fix_plan.md for completion
    # Fix #144: Only match valid markdown checkboxes, not date entries like [2026-01-29]
    # Valid patterns: "- [ ]" (uncompleted) and "- [x]" or "- [X]" (completed)
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local uncompleted_items=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$uncompleted_items" ]] && uncompleted_items=0
        local completed_items=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$completed_items" ]] && completed_items=0
        local total_items=$((uncompleted_items + completed_items))

        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    fi

    echo ""  # Return empty string instead of using return code
}

# =============================================================================
# MODERN CLI HELPER FUNCTIONS (Phase 1.1)
# =============================================================================

# Check Codex CLI version for compatibility with modern flags
check_codex_version() {
    local version=$($CODEX_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version" ]]; then
        log_status "WARN" "Cannot detect Codex CLI version, assuming compatible"
        return 0
    fi

    # Compare versions (simplified semver comparison)
    local required="$CODEX_MIN_VERSION"

    # Convert to comparable integers (major * 10000 + minor * 100 + patch)
    local ver_parts=(${version//./ })
    local req_parts=(${required//./ })

    local ver_num=$((${ver_parts[0]:-0} * 10000 + ${ver_parts[1]:-0} * 100 + ${ver_parts[2]:-0}))
    local req_num=$((${req_parts[0]:-0} * 10000 + ${req_parts[1]:-0} * 100 + ${req_parts[2]:-0}))

    if [[ $ver_num -lt $req_num ]]; then
        log_status "WARN" "Codex CLI version $version < $required. Some features may not work."
        log_status "WARN" "Consider upgrading Codex CLI."
        return 1
    fi

    log_status "INFO" "Codex CLI version $version (>= $required) - modern features enabled"
    return 0
}

# Backward-compatible alias for older tests/scripts.
check_claude_version() {
    check_codex_version "$@"
}

# Detect support for structured exec output flags in local Codex CLI.
detect_codex_structured_output_capabilities() {
    CODEX_SUPPORTS_OUTPUT_LAST_MESSAGE=false
    CODEX_SUPPORTS_OUTPUT_SCHEMA=false

    local help_output
    help_output=$("$CODEX_CODE_CMD" exec --help 2>/dev/null || true)
    if [[ -z "$help_output" ]]; then
        log_status "WARN" "Could not inspect Codex exec --help; structured output flags disabled"
        return 0
    fi

    if echo "$help_output" | grep -q -- "--output-last-message"; then
        CODEX_SUPPORTS_OUTPUT_LAST_MESSAGE=true
    fi
    if echo "$help_output" | grep -q -- "--output-schema"; then
        CODEX_SUPPORTS_OUTPUT_SCHEMA=true
    fi

    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "Codex structured flags: output-last-message=$CODEX_SUPPORTS_OUTPUT_LAST_MESSAGE output-schema=$CODEX_SUPPORTS_OUTPUT_SCHEMA"
    fi
}

# Validate allowed tools against whitelist
# Returns 0 if valid, 1 if invalid with error message
validate_allowed_tools() {
    local tools_input=$1

    if [[ -z "$tools_input" ]]; then
        return 0  # Empty is valid (uses defaults)
    fi

    # Split by comma
    local IFS=','
    read -ra tools <<< "$tools_input"

    for tool in "${tools[@]}"; do
        # Trim whitespace
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -z "$tool" ]]; then
            continue
        fi

        local valid=false

        # Check against valid patterns
        for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
            if [[ "$tool" == "$pattern" ]]; then
                valid=true
                break
            fi

            # Check for Bash(*) pattern - any Bash with parentheses is allowed
            if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                valid=true
                break
            fi
        done

        if [[ "$valid" == "false" ]]; then
            echo "Error: Invalid tool in --allowed-tools: '$tool'"
            echo "Valid tools: ${VALID_TOOL_PATTERNS[*]}"
            echo "Note: Bash(...) patterns with any content are allowed (e.g., 'Bash(git *)')"
            return 1
        fi
    done

    return 0
}

# Build loop context for Codex CLI session
# Provides loop-specific context via --append-system-prompt
build_loop_context() {
    local loop_count=$1
    local context=""

    # Add loop number
    context="Loop #${loop_count}. "

    # Extract incomplete tasks from fix_plan.md
    # Bug #3 Fix: Support indented markdown checkboxes with [[:space:]]* pattern
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$incomplete_tasks" ]] && incomplete_tasks=0
        context+="Remaining tasks: ${incomplete_tasks}. "
    fi

    # Add circuit breaker state
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    fi

    # Add previous loop summary (truncated)
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_summary=$(jq -r '.analysis.work_summary // ""' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null | head -c 200)
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            context+="Previous: ${prev_summary}"
        fi
    fi

    # Limit total length to ~500 chars
    echo "${context:0:500}"
}

# Get session file age in hours (cross-platform)
# Returns: age in hours on stdout, or -1 if stat fails
# Note: Returns 0 for files less than 1 hour old
get_session_file_age_hours() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    # Get file modification time using capability detection
    # Handles macOS with Homebrew coreutils where stat flags differ
    local file_mtime

    # Try GNU stat first (Linux, macOS with Homebrew coreutils)
    if file_mtime=$(stat -c %Y "$file" 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    # Try BSD stat (native macOS)
    elif file_mtime=$(stat -f %m "$file" 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    # Fallback to date -r (most portable)
    elif file_mtime=$(date -r "$file" +%s 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    else
        file_mtime=""
    fi

    # Handle stat failure - return -1 to indicate error
    # This prevents false expiration when stat fails
    if [[ -z "$file_mtime" || "$file_mtime" == "0" ]]; then
        echo "-1"
        return
    fi

    local current_time
    current_time=$(date +%s)

    local age_seconds=$((current_time - file_mtime))
    local age_hours=$((age_seconds / 3600))

    echo "$age_hours"
}

# Initialize or resume Codex thread session (with expiration check)
#
# Session Expiration Strategy:
# - Default expiration: 24 hours (configurable via CODEX_SESSION_EXPIRY_HOURS)
# - 24 hours chosen because: long enough for multi-day projects, short enough
#   to prevent stale context from causing unpredictable behavior
# - Sessions auto-expire to ensure Codex CLI starts fresh periodically
#
# Returns (stdout):
#   - Session ID string: when resuming a valid, non-expired session
#   - Empty string: when starting new session (no file, expired, or stat error)
#
# Return codes:
#   - 0: Always returns success (caller should check stdout for session ID)
#
init_codex_session() {
    if [[ -f "$CODEX_SESSION_FILE" ]]; then
        # Check session age
        local age_hours
        age_hours=$(get_session_file_age_hours "$CODEX_SESSION_FILE")

        # Handle stat failure (-1) - treat as needing new session
        # Don't expire sessions when we can't determine age
        if [[ $age_hours -eq -1 ]]; then
            log_status "WARN" "Could not determine session age, starting new session"
            rm -f "$CODEX_SESSION_FILE"
            echo ""
            return 0
        fi

        # Check if session has expired
        if [[ $age_hours -ge $CODEX_SESSION_EXPIRY_HOURS ]]; then
            log_status "INFO" "Session expired (${age_hours}h old, max ${CODEX_SESSION_EXPIRY_HOURS}h), starting new session"
            rm -f "$CODEX_SESSION_FILE"
            echo ""
            return 0
        fi

        # Session is valid, try to read it
        local session_id=$(cat "$CODEX_SESSION_FILE" 2>/dev/null)
        if [[ -n "$session_id" ]]; then
            log_status "INFO" "Resuming Codex thread: ${session_id:0:20}... (${age_hours}h old)"
            echo "$session_id"
            return 0
        fi
    fi

    log_status "INFO" "Starting new Codex session"
    echo ""
}

# Save session ID after successful execution
save_codex_session() {
    local output_file=$1

    # Try to extract session ID from Codex JSONL output first
    if [[ -f "$output_file" ]]; then
        local session_id=""

        # Codex exec --json format
        session_id=$(jq -r 'select(.type == "thread.started") | .thread_id // empty' "$output_file" 2>/dev/null | head -1)

        # Backward-compatible fallback format
        if [[ -z "$session_id" ]]; then
            session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null)
        fi

        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            echo "$session_id" > "$CODEX_SESSION_FILE"
            log_status "INFO" "Saved Codex thread: ${session_id:0:20}..."
        fi
    fi
}

# =============================================================================
# SESSION LIFECYCLE MANAGEMENT FUNCTIONS (Phase 1.2)
# =============================================================================

# Get current session ID from Ralph session file
# Returns: session ID string or empty if not found
get_session_id() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        echo ""
        return 0
    fi

    # Extract session_id from JSON file (SC2155: separate declare from assign)
    local session_id
    session_id=$(jq -r '.session_id // ""' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    # Handle jq failure or null/empty results
    if [[ $jq_status -ne 0 || -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=""
    fi
    echo "$session_id"
    return 0
}

# Reset session with reason logging
# Usage: reset_session "reason_for_reset"
reset_session() {
    local reason=${1:-"manual_reset"}

    # Get current timestamp
    local reset_timestamp
    reset_timestamp=$(get_iso_timestamp)

    # Always create/overwrite the session file using jq for safe JSON escaping
    jq -n \
        --arg session_id "" \
        --arg created_at "" \
        --arg last_used "" \
        --arg reset_at "$reset_timestamp" \
        --arg reset_reason "$reason" \
        '{
            session_id: $session_id,
            created_at: $created_at,
            last_used: $last_used,
            reset_at: $reset_at,
            reset_reason: $reset_reason
        }' > "$RALPH_SESSION_FILE"

    # Also clear the Codex CLI session file for consistency
    rm -f "$CODEX_SESSION_FILE" 2>/dev/null

    # Clear exit signals to prevent stale completion indicators from causing premature exit (issue #91)
    # This ensures a fresh start without leftover state from previous sessions
    if [[ -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
        [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "INFO" "Cleared exit signals file"
    fi

    # Clear response analysis to prevent stale EXIT_SIGNAL from previous session
    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null

    # Log the session transition (non-fatal to prevent script exit under set -e)
    log_session_transition "active" "reset" "$reason" "${loop_count:-0}" || true

    log_status "INFO" "Session reset: $reason"
}

# Log session state transitions to history file
# Usage: log_session_transition from_state to_state reason loop_number
log_session_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=${4:-0}

    # Get timestamp once (SC2155: separate declare from assign)
    local ts
    ts=$(get_iso_timestamp)

    # Create transition entry using jq for safe JSON (SC2155: separate declare from assign)
    local transition
    transition=$(jq -n -c \
        --arg timestamp "$ts" \
        --arg from_state "$from_state" \
        --arg to_state "$to_state" \
        --arg reason "$reason" \
        --argjson loop_number "$loop_number" \
        '{
            timestamp: $timestamp,
            from_state: $from_state,
            to_state: $to_state,
            reason: $reason,
            loop_number: $loop_number
        }')

    # Read history file defensively - fallback to empty array on any failure
    local history
    if [[ -f "$RALPH_SESSION_HISTORY_FILE" ]]; then
        history=$(cat "$RALPH_SESSION_HISTORY_FILE" 2>/dev/null)
        # Validate JSON, fallback to empty array if corrupted
        if ! echo "$history" | jq empty 2>/dev/null; then
            history='[]'
        fi
    else
        history='[]'
    fi

    # Append transition and keep only last 50 entries
    local updated_history
    updated_history=$(echo "$history" | jq ". += [$transition] | .[-50:]" 2>/dev/null)
    local jq_status=$?

    # Only write if jq succeeded
    if [[ $jq_status -eq 0 && -n "$updated_history" ]]; then
        echo "$updated_history" > "$RALPH_SESSION_HISTORY_FILE"
    else
        # Fallback: start fresh with just this transition
        echo "[$transition]" > "$RALPH_SESSION_HISTORY_FILE"
    fi
}

# Generate a unique session ID using timestamp and random component
generate_session_id() {
    local ts
    ts=$(date +%s)
    local rand
    rand=$RANDOM
    echo "ralph-${ts}-${rand}"
}

# Initialize session tracking (called at loop start)
init_session_tracking() {
    local ts
    ts=$(get_iso_timestamp)

    # Create session file if it doesn't exist
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "" \
            --arg reset_reason "" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"

        log_status "INFO" "Initialized session tracking (session: $new_session_id)"
        return 0
    fi

    # Validate existing session file
    if ! jq empty "$RALPH_SESSION_FILE" 2>/dev/null; then
        log_status "WARN" "Corrupted session file detected, recreating..."
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "$ts" \
            --arg reset_reason "corrupted_file_recovery" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"
    fi
}

# Update last_used timestamp in session file (called on each loop iteration)
update_session_last_used() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        return 0
    fi

    local ts
    ts=$(get_iso_timestamp)

    # Update last_used in existing session file
    local updated
    updated=$(jq --arg last_used "$ts" '.last_used = $last_used' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    if [[ $jq_status -eq 0 && -n "$updated" ]]; then
        echo "$updated" > "$RALPH_SESSION_FILE"
    fi
}

# Global array for Codex command arguments (avoids shell injection)
declare -a CODEX_CMD_ARGS=()

# Append optional Codex runtime controls to CODEX_CMD_ARGS.
append_codex_runtime_flags() {
    if [[ -n "$CODEX_SANDBOX_MODE" ]]; then
        CODEX_CMD_ARGS+=("--sandbox" "$CODEX_SANDBOX_MODE")
    fi
    if [[ "$CODEX_FULL_AUTO" == "true" ]]; then
        CODEX_CMD_ARGS+=("--full-auto")
    fi
    if [[ "$CODEX_DANGEROUS_BYPASS" == "true" ]]; then
        CODEX_CMD_ARGS+=("--dangerously-bypass-approvals-and-sandbox")
    fi
    if [[ -n "$CODEX_PROFILE" ]]; then
        CODEX_CMD_ARGS+=("--profile" "$CODEX_PROFILE")
    fi
    if [[ -n "$CODEX_CWD" ]]; then
        CODEX_CMD_ARGS+=("--cd" "$CODEX_CWD")
    fi
    if [[ -n "$CODEX_ADD_DIRS" ]]; then
        local IFS=','
        read -ra add_dirs <<< "$CODEX_ADD_DIRS"
        local add_dir
        for add_dir in "${add_dirs[@]}"; do
            add_dir=$(echo "$add_dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$add_dir" ]]; then
                CODEX_CMD_ARGS+=("--add-dir" "$add_dir")
            fi
        done
    fi
    if [[ "$CODEX_SKIP_GIT_REPO_CHECK" == "true" ]]; then
        CODEX_CMD_ARGS+=("--skip-git-repo-check")
    fi
    if [[ "$CODEX_EPHEMERAL" == "true" ]]; then
        CODEX_CMD_ARGS+=("--ephemeral")
    fi
}

# Append optional structured output flags when the installed Codex CLI supports them.
append_codex_structured_output_flags() {
    if [[ "$CODEX_SUPPORTS_OUTPUT_LAST_MESSAGE" == "true" && -n "$CODEX_LAST_MESSAGE_FILE" ]]; then
        CODEX_CMD_ARGS+=("--output-last-message" "$CODEX_LAST_MESSAGE_FILE")
    fi

    if [[ "$CODEX_SUPPORTS_OUTPUT_SCHEMA" == "true" && -n "$CODEX_OUTPUT_SCHEMA_FILE" && -f "$CODEX_OUTPUT_SCHEMA_FILE" ]]; then
        CODEX_CMD_ARGS+=("--output-schema" "$CODEX_OUTPUT_SCHEMA_FILE")
    fi
}

# Pick best analysis source by precedence: structured last message, JSONL events, fallback output log.
select_analysis_input_file() {
    local last_message_file=$1
    local jsonl_file=$2
    local output_file=$3

    if [[ -f "$last_message_file" && -s "$last_message_file" ]]; then
        echo "$last_message_file"
    elif [[ -f "$jsonl_file" && -s "$jsonl_file" ]]; then
        echo "$jsonl_file"
    else
        echo "$output_file"
    fi
}

# Build Codex CLI command with modern flags using array (shell-injection safe)
# Populates global CODEX_CMD_ARGS array for direct execution
# Uses positional prompt argument for codex exec / codex exec resume
build_codex_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3

    # Reset global array
    CODEX_CMD_ARGS=("$CODEX_CODE_CMD" "exec")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        log_status "ERROR" "Prompt file not found: $prompt_file"
        return 1
    fi

    # Codex only supports JSONL structured output for machine parsing
    CODEX_CMD_ARGS+=("--json")

    # If session continuity is enabled and we have a thread id, switch to "exec resume"
    if [[ "$CODEX_USE_CONTINUE" == "true" && -n "$session_id" ]]; then
        CODEX_CMD_ARGS=("$CODEX_CODE_CMD" "exec" "resume" "--json" "$session_id")
    fi
    append_codex_runtime_flags
    append_codex_structured_output_flags

    # Read prompt file content and append loop context inline
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    if [[ -n "$loop_context" ]]; then
        prompt_content=$(cat <<EOF
[RALPH LOOP CONTEXT]
$loop_context
[/RALPH LOOP CONTEXT]

$prompt_content
EOF
)
    fi

    CODEX_CMD_ARGS+=("$prompt_content")
}

# Backward-compatible aliases for older tests/scripts.
build_claude_command() {
    build_codex_command "$@"
}

# Main execution function
execute_codex_code() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/codex_output_${timestamp}.log"
    local jsonl_file="$LOG_DIR/codex_events_${timestamp}.jsonl"
    local stderr_file="$LOG_DIR/codex_stderr_${timestamp}.log"
    local last_message_file="$LOG_DIR/codex_last_message_${timestamp}.txt"
    local loop_count=$1
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    calls_made=$((calls_made + 1))

    # Fix #141: Capture git HEAD SHA at loop start to detect commits as progress
    # Store in file for access by progress detection after Codex CLI execution
    local loop_start_sha=""
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        loop_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    fi
    echo "$loop_start_sha" > "$RALPH_DIR/.loop_start_sha"

    log_status "LOOP" "Executing Codex CLI (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((CODEX_TIMEOUT_MINUTES * 60))
    log_status "INFO" "⏳ Starting Codex CLI execution... (timeout: ${CODEX_TIMEOUT_MINUTES}m)"

    # Build loop context for session continuity
    local loop_context=""
    if [[ "$CODEX_USE_CONTINUE" == "true" ]]; then
        loop_context=$(build_loop_context "$loop_count")
        if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
            log_status "INFO" "Loop context: $loop_context"
        fi
    fi

    # Initialize or resume session (Codex thread id)
    local session_id=""
    if [[ "$CODEX_USE_CONTINUE" == "true" ]]; then
        session_id=$(init_codex_session)
    fi

    # Make last message output file available while building the Codex command.
    CODEX_LAST_MESSAGE_FILE="$last_message_file"

    # Codex is executed in JSONL mode and converted to message text post-run.
    # Live streaming mode from legacy stream-json is not supported in this path yet.
    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        log_status "WARN" "Live mode is currently disabled for Codex CLI execution. Falling back to background mode."
        LIVE_OUTPUT=false
    fi

    if ! build_codex_command "$PROMPT_FILE" "$loop_context" "$session_id"; then
        log_status "ERROR" "❌ Failed to build Codex CLI command"
        return 1
    fi

    # Execute Codex CLI
    local exit_code=0

    # Initialize live.log for this execution
    echo -e "\n\n=== Loop #$loop_count - $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LIVE_LOG_FILE"
    # BACKGROUND MODE with progress monitoring
    if portable_timeout ${timeout_seconds}s "${CODEX_CMD_ARGS[@]}" < /dev/null > "$jsonl_file" 2> "$stderr_file" &
    then
        :  # Continue to wait loop
    else
        log_status "ERROR" "❌ Failed to start Codex CLI process"
        return 1
    fi

    # Get PID and monitor progress
    local codex_pid=$!
    local progress_counter=0

    # Show progress while Codex is running
    while kill -0 $codex_pid 2>/dev/null; do
        progress_counter=$((progress_counter + 1))
        case $((progress_counter % 4)) in
            1) progress_indicator="⠋" ;;
            2) progress_indicator="⠙" ;;
            3) progress_indicator="⠹" ;;
            0) progress_indicator="⠸" ;;
        esac

        # Get last line from output if available
        local last_line=""
        if [[ -f "$jsonl_file" && -s "$jsonl_file" ]]; then
            last_line=$(tail -1 "$jsonl_file" 2>/dev/null | head -c 80)
            cp "$jsonl_file" "$LIVE_LOG_FILE" 2>/dev/null
        fi

        # Update progress file for monitor
        cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

        # Only log if verbose mode is enabled
        if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
            if [[ -n "$last_line" ]]; then
                log_status "INFO" "$progress_indicator Codex: $last_line... (${progress_counter}0s)"
            else
                log_status "INFO" "$progress_indicator Codex working... (${progress_counter}0s elapsed)"
            fi
        fi

        sleep 10
    done

    # Wait for the process to finish and get exit code
    wait $codex_pid
    exit_code=$?

    # Convert Codex JSONL output to plain assistant message text for analyzer
    if [[ -f "$jsonl_file" && -s "$jsonl_file" ]]; then
        jq -r 'select(.type == "item.completed" and .item.type == "agent_message") | .item.text' "$jsonl_file" > "$output_file" 2>/dev/null || true

        # If no agent message extracted, keep raw events for debugging
        if [[ ! -s "$output_file" ]]; then
            cp "$jsonl_file" "$output_file"
        fi
    fi

    # Append stderr diagnostics to output log (if any)
    if [[ -f "$stderr_file" && -s "$stderr_file" ]]; then
        {
            echo ""
            echo "--- CODEX STDERR ---"
            cat "$stderr_file"
        } >> "$output_file"
    fi

    if [ $exit_code -eq 0 ]; then
        # Only increment counter on successful execution
        echo "$calls_made" > "$CALL_COUNT_FILE"

        # Clear progress file
        echo '{"status": "completed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "✅ Codex CLI execution completed successfully"

        # Save thread ID from Codex JSONL output (session continuity)
        if [[ "$CODEX_USE_CONTINUE" == "true" ]]; then
            save_codex_session "$jsonl_file"
        fi

        # Analyze JSONL events directly when available to preserve structured signals.
        log_status "INFO" "🔍 Analyzing Codex response..."
        local analysis_input_file
        analysis_input_file=$(select_analysis_input_file "$last_message_file" "$jsonl_file" "$output_file")
        analyze_response "$analysis_input_file" "$loop_count"
        local analysis_exit_code=$?

        # Update exit signals based on analysis
        update_exit_signals

        # Log analysis summary
        log_analysis_summary

        # Get file change count for circuit breaker
        # Fix #141: Detect both uncommitted changes AND committed changes
        local files_changed=0
        local loop_start_sha=""
        local current_sha=""

        if [[ -f "$RALPH_DIR/.loop_start_sha" ]]; then
            loop_start_sha=$(cat "$RALPH_DIR/.loop_start_sha" 2>/dev/null || echo "")
        fi

        if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
            current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

            # Check if commits were made (HEAD changed)
            if [[ -n "$loop_start_sha" && -n "$current_sha" && "$loop_start_sha" != "$current_sha" ]]; then
                # Commits were made - count union of committed files AND working tree changes
                # This catches cases where Codex CLI commits some files but still has other modified files
                files_changed=$(
                    {
                        git diff --name-only "$loop_start_sha" "$current_sha" 2>/dev/null
                        git diff --name-only HEAD 2>/dev/null           # unstaged changes
                        git diff --name-only --cached 2>/dev/null       # staged changes
                    } | sort -u | wc -l
                )
                [[ "$VERBOSE_PROGRESS" == "true" ]] && log_status "DEBUG" "Detected $files_changed unique files changed (commits + working tree) since loop start"
            else
                # No commits - check for uncommitted changes (staged + unstaged)
                files_changed=$(
                    {
                        git diff --name-only 2>/dev/null                # unstaged changes
                        git diff --name-only --cached 2>/dev/null       # staged changes
                    } | sort -u | wc -l
                )
            fi
        fi

        local has_errors="false"

        # Two-stage error detection to avoid JSON field false positives
        # Stage 1: Filter out JSON field patterns like "is_error": false
        # Stage 2: Look for actual error messages in specific contexts
        # Avoid type annotations like "error: Error" by requiring lowercase after ": error"
        if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
           grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
            has_errors="true"

            # Debug logging: show what triggered error detection
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                log_status "DEBUG" "Error patterns found:"
                grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
                    grep -nE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' | \
                    head -3 | while IFS= read -r line; do
                    log_status "DEBUG" "  $line"
                done
            fi

            log_status "WARN" "Errors detected in output, check: $output_file"
        fi
        local output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        # Record result in circuit breaker
        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        local circuit_result=$?

        if [[ $circuit_result -ne 0 ]]; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        fi

        return 0
    else
        # Clear progress file on failure
        echo '{"status": "failed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        # Check if the failure is due to provider usage limits
        if grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached" "$output_file"; then
            log_status "ERROR" "🚫 API usage limit reached"
            return 2  # Special return code for API limit
        else
            log_status "ERROR" "❌ Codex CLI execution failed, check: $output_file"
            return 1
        fi
    fi
}

# Backward-compatible aliases for older tests/scripts.
init_claude_session() {
    init_codex_session "$@"
}

save_claude_session() {
    save_codex_session "$@"
}

execute_claude_code() {
    execute_codex_code "$@"
}

# Cleanup function
cleanup() {
    log_status "INFO" "Ralph loop interrupted. Cleaning up..."
    reset_session "manual_interrupt"
    update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "interrupted" "stopped"
    release_instance_lock
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM
trap release_instance_lock EXIT

# Global variable for loop count (needed by cleanup function)
loop_count=0

# Main loop
main() {
    # Load project-specific configuration from .ralphrc
    if load_ralphrc; then
        if [[ "$RALPHRC_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from .ralphrc"
        fi
    fi

    log_status "SUCCESS" "🚀 Ralph loop starting with Codex CLI"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"
    check_codex_version || true
    detect_codex_structured_output_capabilities

    # Check if project uses old flat structure and needs migration
    if [[ -f "PROMPT.md" ]] && [[ ! -d ".ralph" ]]; then
        log_status "ERROR" "This project uses the old flat structure."
        echo ""
        echo "Ralph v0.10.0+ uses a .ralph/ subfolder to keep your project root clean."
        echo ""
        echo "To upgrade your project, run:"
        echo "  ralph-migrate"
        echo ""
        echo "This will move Ralph-specific files to .ralph/ while preserving src/ at root."
        echo "A backup will be created before migration."
        exit 1
    fi

    # Check if this is a Ralph project directory
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        
        # Check if this looks like a partial Ralph project
        if [[ -f "$RALPH_DIR/fix_plan.md" ]] || [[ -d "$RALPH_DIR/specs" ]] || [[ -f "$RALPH_DIR/AGENT.md" ]]; then
            echo "This appears to be a Ralph project but is missing .ralph/PROMPT.md."
            echo "You may need to create or restore the PROMPT.md file."
        else
            echo "This directory is not a Ralph project."
        fi

        echo ""
        echo "To fix this:"
        echo "  1. Enable Ralph in existing project: ralph-enable"
        echo "  2. Create a new project: ralph-setup my-project"
        echo "  3. Import existing requirements: ralph-import requirements.md"
        echo "  4. Navigate to an existing Ralph project directory"
        echo "  5. Or create .ralph/PROMPT.md manually in this directory"
        echo ""
        echo "Ralph projects should contain: .ralph/PROMPT.md, .ralph/fix_plan.md, .ralph/specs/, src/, etc."
        exit 1
    fi

    # Initialize session tracking before entering the loop
    init_session_tracking

    # Prevent concurrent Ralph loops in the same project.
    if ! acquire_instance_lock; then
        exit 1
    fi

    log_status "INFO" "Starting main loop..."
    
    while true; do
        loop_count=$((loop_count + 1))

        # Update session last_used timestamp
        update_session_last_used

        log_status "INFO" "Loop #$loop_count - calling init_call_tracking..."
        init_call_tracking
        
        log_status "LOOP" "=== Starting Loop #$loop_count ==="
        
        # Check circuit breaker before attempting execution
        if should_halt_execution; then
            reset_session "circuit_breaker_open"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - execution halted"
            break
        fi

        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi

        # Check for graceful exit conditions
        local exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            # Handle permission_denied specially (Issue #101)
            if [[ "$exit_reason" == "permission_denied" ]]; then
                log_status "ERROR" "🚫 Permission denied - halting loop"
                reset_session "permission_denied"
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "permission_denied" "halted" "permission_denied"

                # Display helpful guidance for resolving permission issues
                echo ""
                echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${RED}║  PERMISSION DENIED - Loop Halted                          ║${NC}"
                echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${YELLOW}The coding agent was denied permission to execute commands.${NC}"
                echo ""
                echo -e "${YELLOW}To fix this:${NC}"
                echo "  1. Review Codex approval/sandbox settings for this environment"
                echo "  2. Re-run with the proper policy (example: approval_policy=\"on-request\")"
                echo ""
                echo -e "${YELLOW}After updating .ralphrc:${NC}"
                echo "  ralph --reset-session  # Clear stale session state"
                echo "  ralph --monitor        # Restart the loop"
                echo ""

                break
            fi

            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            reset_session "project_complete"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(cat "$CALL_COUNT_FILE")"
            log_status "INFO" "  - Exit reason: $exit_reason"

            break
        fi
        
        # Update status
        local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"
        
        # Execute Codex CLI
        execute_codex_code "$loop_count"
        local exec_result=$?
        
        if [ $exec_result -eq 0 ]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"

            # Brief pause between successful executions
            sleep 5
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened
            reset_session "circuit_breaker_trip"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph --reset-circuit' to reset the circuit breaker after addressing issues"
            break
        elif [ $exec_result -eq 2 ]; then
            # API 5-hour limit reached - handle specially
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit" "paused"
            log_status "WARN" "🛑 API usage limit reached!"
            
            # Ask user whether to wait or exit
            echo -e "\n${YELLOW}A provider usage limit was reached.${NC}"
            echo -e "${YELLOW}You can either:${NC}"
            echo -e "  ${GREEN}1)${NC} Wait for the limit to reset (usually within an hour)"
            echo -e "  ${GREEN}2)${NC} Exit the loop and try again later"
            echo -e "\n${BLUE}Choose an option (1 or 2):${NC} "
            
            # Read user input with timeout
            read -t 30 -n 1 user_choice
            echo  # New line after input
            
            if [[ "$user_choice" == "2" ]] || [[ -z "$user_choice" ]]; then
                log_status "INFO" "User chose to exit (or timed out). Exiting loop..."
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit_exit" "stopped" "api_5hour_limit"
                break
            else
                log_status "INFO" "User chose to wait. Waiting for API limit reset..."
                # Wait for longer period when API limit is hit
                local wait_minutes=60
                log_status "INFO" "Waiting $wait_minutes minutes before retrying..."
                
                # Countdown display
                local wait_seconds=$((wait_minutes * 60))
                while [[ $wait_seconds -gt 0 ]]; do
                    local minutes=$((wait_seconds / 60))
                    local seconds=$((wait_seconds % 60))
                    printf "\r${YELLOW}Time until retry: %02d:%02d${NC}" $minutes $seconds
                    sleep 1
                    ((wait_seconds--))
                done
                printf "\n"
            fi
        else
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "failed" "error"
            log_status "WARN" "Execution failed, waiting 30 seconds before retry..."
            sleep 30
        fi
        
        log_status "LOOP" "=== Completed Loop #$loop_count ==="
    done
}

# Help function
show_help() {
    cat << HELPEOF
Ralph Loop for Codex CLI

Usage: $0 [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -l, --live              Deprecated compatibility flag (ignored; Codex runs in JSONL mode)
    -t, --timeout MIN       Set Codex execution timeout in minutes (default: $CODEX_TIMEOUT_MINUTES)
    --sandbox MODE          Set Codex sandbox mode: read-only|workspace-write|danger-full-access
    --full-auto             Convenience mode: on-request approvals + workspace-write sandbox
    --dangerously-bypass-approvals-and-sandbox
                            Disable approvals and sandbox (dangerous)
    --profile NAME          Use Codex profile from ~/.codex/config.toml
    --cd DIR                Set Codex working directory root
    --add-dir DIR           Add extra writable directory (repeatable)
    --skip-git-repo-check   Allow running Codex outside git repositories
    --ephemeral             Run Codex without persisting session files
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit
    --auto-reset-circuit    Auto-reset circuit breaker on startup (bypasses cooldown)
    --reset-session         Reset session state and exit (clears session continuity)

Deprecated Compatibility Options:
    --output-format FORMAT  Deprecated no-op (Codex always runs with --json events)
    --allowed-tools TOOLS   Deprecated no-op (tool filtering is not applied in Codex mode)
    --no-continue           Disable session continuity across loops
    --session-expiry HOURS  Set session expiration time in hours (default: $CODEX_SESSION_EXPIRY_HOURS)

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)
    - .ralph/.ralph_session: Session lifecycle tracking
    - .ralph/.ralph_session_history: Session transition history (last 50)
    - .ralph/.call_count: API call counter for rate limiting
    - .ralph/.last_reset: Timestamp of last rate limit reset

Example workflow:
    ralph-setup my-project     # Create project
    cd my-project             # Enter project directory
    $0 --monitor             # Start Ralph with monitoring

Examples:
    $0 --calls 50 --prompt my_prompt.md
    $0 --monitor             # Start with integrated tmux monitoring
    $0 --live                # Deprecated compatibility flag (ignored)
    $0 --live --verbose      # Verbose mode + deprecated live flag
    $0 --monitor --timeout 30   # 30-minute timeout for complex tasks
    $0 --verbose --timeout 5    # 5-minute timeout with detailed progress
    $0 --sandbox workspace-write --full-auto
    $0 --profile ci --ephemeral --skip-git-repo-check
    $0 --output-format text  # Deprecated compatibility flag (ignored)
    $0 --no-continue            # Disable session continuity
    $0 --session-expiry 48      # 48-hour session expiration

HELPEOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -s|--status)
            if [[ -f "$STATUS_FILE" ]]; then
                echo "Current Status:"
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph may not be running."
            fi
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_PROGRESS=true
            shift
            ;;
        -l|--live)
            LIVE_OUTPUT=true
            echo "WARN: --live is deprecated in Codex mode and currently ignored." >&2
            shift
            ;;
        -t|--timeout)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$2" -le 120 ]]; then
                CODEX_TIMEOUT_MINUTES="$2"
                CLAUDE_TIMEOUT_MINUTES="$CODEX_TIMEOUT_MINUTES"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
        --sandbox)
            if [[ -z "$2" ]]; then
                echo "Error: --sandbox requires a mode: read-only|workspace-write|danger-full-access"
                exit 1
            fi
            case "$2" in
                read-only|workspace-write|danger-full-access)
                    CODEX_SANDBOX_MODE="$2"
                    ;;
                *)
                    echo "Error: --sandbox must be one of: read-only, workspace-write, danger-full-access"
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --full-auto)
            if [[ "$CODEX_DANGEROUS_BYPASS" == "true" ]]; then
                echo "Error: --full-auto cannot be used with --dangerously-bypass-approvals-and-sandbox"
                exit 1
            fi
            CODEX_FULL_AUTO=true
            shift
            ;;
        --dangerously-bypass-approvals-and-sandbox)
            if [[ "$CODEX_FULL_AUTO" == "true" ]]; then
                echo "Error: --dangerously-bypass-approvals-and-sandbox cannot be used with --full-auto"
                exit 1
            fi
            CODEX_DANGEROUS_BYPASS=true
            shift
            ;;
        --profile)
            if [[ -z "$2" ]]; then
                echo "Error: --profile requires a profile name"
                exit 1
            fi
            CODEX_PROFILE="$2"
            shift 2
            ;;
        --cd)
            if [[ -z "$2" ]]; then
                echo "Error: --cd requires a directory path"
                exit 1
            fi
            CODEX_CWD="$2"
            shift 2
            ;;
        --add-dir)
            if [[ -z "$2" ]]; then
                echo "Error: --add-dir requires a directory path"
                exit 1
            fi
            if [[ -n "$CODEX_ADD_DIRS" ]]; then
                CODEX_ADD_DIRS="$CODEX_ADD_DIRS,$2"
            else
                CODEX_ADD_DIRS="$2"
            fi
            shift 2
            ;;
        --skip-git-repo-check)
            CODEX_SKIP_GIT_REPO_CHECK=true
            shift
            ;;
        --ephemeral)
            CODEX_EPHEMERAL=true
            shift
            ;;
        --reset-circuit)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_circuit_breaker "Manual reset via command line"
            reset_session "manual_circuit_reset"
            exit 0
            ;;
        --reset-session)
            # Reset session state only
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_session "manual_reset_flag"
            echo -e "\033[0;32m✅ Session state reset successfully\033[0m"
            exit 0
            ;;
        --circuit-status)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            show_circuit_status
            exit 0
            ;;
        --output-format)
            if [[ "$2" == "json" || "$2" == "text" ]]; then
                CODEX_OUTPUT_FORMAT="$2"
                CLAUDE_OUTPUT_FORMAT="$CODEX_OUTPUT_FORMAT"
                echo "WARN: --output-format is deprecated and has no effect in Codex mode." >&2
            else
                echo "Error: --output-format must be 'json' or 'text'"
                exit 1
            fi
            shift 2
            ;;
        --allowed-tools)
            if ! validate_allowed_tools "$2"; then
                exit 1
            fi
            CODEX_ALLOWED_TOOLS="$2"
            CLAUDE_ALLOWED_TOOLS="$CODEX_ALLOWED_TOOLS"
            echo "WARN: --allowed-tools is deprecated and has no effect in Codex mode." >&2
            shift 2
            ;;
        --no-continue)
            CODEX_USE_CONTINUE=false
            CLAUDE_USE_CONTINUE="$CODEX_USE_CONTINUE"
            shift
            ;;
        --session-expiry)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --session-expiry requires a positive integer (hours)"
                exit 1
            fi
            CODEX_SESSION_EXPIRY_HOURS="$2"
            CLAUDE_SESSION_EXPIRY_HOURS="$CODEX_SESSION_EXPIRY_HOURS"
            shift 2
            ;;
        --auto-reset-circuit)
            CB_AUTO_RESET=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Only execute when run directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # If tmux mode requested, set it up
    if [[ "$USE_TMUX" == "true" ]]; then
        check_tmux_available
        setup_tmux_session
    fi

    # Start the main loop
    main
fi
