#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/lib/date_utils.sh"
source "$REPO_ROOT/lib/timeout_utils.sh"
source "$REPO_ROOT/lib/response_analyzer.sh"
source "$REPO_ROOT/lib/circuit_breaker.sh"

RALPH_DIR="${RALPH_DIR:-.ralph}"
LOG_DIR="$RALPH_DIR/logs"
PROMPT_FILE="${PROMPT_FILE:-$RALPH_DIR/PROMPT.md}"
FIX_PLAN_FILE="${FIX_PLAN_FILE:-$RALPH_DIR/fix_plan.md}"
MAX_LOOPS="${MAX_LOOPS:-10}"
GEMINI_CMD="${GEMINI_CMD:-gemini}"
GEMINI_MODEL="${GEMINI_MODEL:-}"
GEMINI_FALLBACK_MODELS="${GEMINI_FALLBACK_MODELS:-gemini-2.5-flash}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"
GEMINI_TIMEOUT_MINUTES="${GEMINI_TIMEOUT_MINUTES:-15}"
GEMINI_APPROVAL_MODE="${GEMINI_APPROVAL_MODE:-yolo}"
LOG_FILE="$LOG_DIR/ralph-gemini.log"

log_msg() {
  local level="$1"
  local message="$2"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  mkdir -p "$LOG_DIR"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$message" | tee -a "$LOG_FILE"
}

require_command() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_msg "ERROR" "Command not found: $cmd. $hint"
    return 1
  fi
}

usage() {
  cat <<USAGE
Usage: ralph-gemini-loop.sh [OPTIONS]

Options:
  --prompt FILE        Prompt file (default: .ralph/PROMPT.md)
  --fix-plan FILE      Fix plan file (default: .ralph/fix_plan.md)
  --max-loops N        Number of iterations (default: 10)
  --model NAME         Gemini model (optional)
  --sleep N            Seconds between loops (default: 2)
  --help               Show this help

Environment:
  GEMINI_CMD             Gemini CLI command (default: gemini)
  GEMINI_TIMEOUT_MINUTES Timeout per loop execution (default: 15)
  GEMINI_APPROVAL_MODE   Approval mode for non-interactive execution (default: yolo)
  GEMINI_FALLBACK_MODELS Comma-separated fallback models for quota errors
USAGE
}

is_quota_or_capacity_error() {
  local stderr_path="$1"
  grep -qiE \
    'exhausted your capacity|quota will reset|resource has been exhausted|rate limit|too many requests|status[^0-9]*429' \
    "$stderr_path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      PROMPT_FILE="$2"
      shift 2
      ;;
    --fix-plan)
      FIX_PLAN_FILE="$2"
      shift 2
      ;;
    --max-loops)
      MAX_LOOPS="$2"
      shift 2
      ;;
    --model)
      GEMINI_MODEL="$2"
      shift 2
      ;;
    --sleep)
      SLEEP_SECONDS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$RALPH_DIR" "$LOG_DIR"
require_command "$GEMINI_CMD" "Install with: npm i -g @google/gemini-cli" || exit 1
require_command "jq" "Install jq to enable response analysis and circuit breaker" || exit 1

if [[ ! -f "$PROMPT_FILE" ]]; then
  log_msg "ERROR" "Prompt file not found: $PROMPT_FILE"
  exit 1
fi

if [[ ! "$MAX_LOOPS" =~ ^[0-9]+$ ]] || [[ "$MAX_LOOPS" -lt 1 ]]; then
  log_msg "ERROR" "Invalid --max-loops value: $MAX_LOOPS"
  exit 1
fi

AGENT_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
AGENT_EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
LAST_OUTPUT_FILE="$RALPH_DIR/.gemini_last_output"

init_circuit_breaker
log_msg "INFO" "Starting Ralph Gemini loop (max_loops=$MAX_LOOPS)"

for ((i=1; i<=MAX_LOOPS; i++)); do
  if should_halt_execution; then
    log_msg "ERROR" "Circuit breaker is OPEN. Halting loop before iteration $i."
    exit 3
  fi

  ts="$(date +%Y%m%d_%H%M%S)"
  output_file="$LOG_DIR/agent_output_${ts}.log"
  stderr_file="$LOG_DIR/gemini_stderr_${ts}.log"

  prompt_payload="$(cat "$PROMPT_FILE")"
  prompt_payload+=$'\n\nNon-interactive execution constraints:\n'
  prompt_payload+='- Do NOT call ask_user.\n'
  prompt_payload+='- Use only tools currently available in this runtime (call cli_help first if unsure).\n'
  prompt_payload+='- If a tool is unavailable, continue with alternatives and explain briefly.'
  if [[ -f "$FIX_PLAN_FILE" ]]; then
    prompt_payload+=$'\n\nCurrent fix plan:\n'
    prompt_payload+="$(cat "$FIX_PLAN_FILE")"
  fi

  log_msg "INFO" "Loop $i/$MAX_LOOPS: calling Gemini"

  model_candidates=()
  if [[ -n "$GEMINI_MODEL" ]]; then
    model_candidates+=("$GEMINI_MODEL")
  fi
  if [[ -n "$GEMINI_FALLBACK_MODELS" ]]; then
    IFS=',' read -r -a fallback_models <<< "$GEMINI_FALLBACK_MODELS"
    for fallback_model in "${fallback_models[@]}"; do
      fallback_model="$(echo "$fallback_model" | xargs)"
      if [[ -z "$fallback_model" ]]; then
        continue
      fi
      if [[ -n "$GEMINI_MODEL" && "$fallback_model" == "$GEMINI_MODEL" ]]; then
        continue
      fi
      model_candidates+=("$fallback_model")
    done
  fi
  if [[ "${#model_candidates[@]}" -eq 0 ]]; then
    model_candidates+=("__auto__")
  fi

  exit_code=1
  for model_candidate in "${model_candidates[@]}"; do
    cmd=("$GEMINI_CMD")
    if [[ "$model_candidate" != "__auto__" ]]; then
      cmd+=("--model" "$model_candidate")
      log_msg "INFO" "Using Gemini model: $model_candidate"
    else
      log_msg "INFO" "Using Gemini default model selection"
    fi
    if [[ -n "$GEMINI_APPROVAL_MODE" ]]; then
      cmd+=("--approval-mode" "$GEMINI_APPROVAL_MODE")
    fi
    cmd+=("--prompt" "$prompt_payload")

    set +e
    if has_timeout_command; then
      portable_timeout "${GEMINI_TIMEOUT_MINUTES}m" "${cmd[@]}" >"$output_file" 2>"$stderr_file"
    else
      log_msg "WARN" "No timeout command found; running without timeout protection."
      "${cmd[@]}" >"$output_file" 2>"$stderr_file"
    fi
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
      break
    fi
    if [[ $exit_code -eq 124 ]]; then
      break
    fi
    if is_quota_or_capacity_error "$stderr_file"; then
      log_msg "WARN" "Quota/capacity error with model '$model_candidate'. Trying next fallback model."
      continue
    fi
    break
  done

  if [[ $exit_code -ne 0 ]]; then
    if [[ $exit_code -eq 124 ]]; then
      log_msg "ERROR" "Gemini timed out after ${GEMINI_TIMEOUT_MINUTES} minute(s). Check $stderr_file"
      exit 124
    fi
    log_msg "ERROR" "Gemini failed (exit=$exit_code). Check $stderr_file"
    exit "$exit_code"
  fi

  cp "$output_file" "$LAST_OUTPUT_FILE"

  analyze_response "$output_file" "$i" "$AGENT_ANALYSIS_FILE" || true
  update_exit_signals "$AGENT_ANALYSIS_FILE" "$AGENT_EXIT_SIGNALS_FILE" || true
  log_analysis_summary "$AGENT_ANALYSIS_FILE" || true

  files_changed=$(jq -r '.analysis.files_modified // 0' "$AGENT_ANALYSIS_FILE" 2>/dev/null || echo "0")
  has_errors="false"
  if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
     grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
    has_errors="true"
  fi
  output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

  if ! record_loop_result "$i" "$files_changed" "$has_errors" "$output_length"; then
    log_msg "ERROR" "Circuit breaker opened after loop $i. Halting execution."
    exit 3
  fi

  analysis_exit_signal=$(jq -r '.analysis.exit_signal // false' "$AGENT_ANALYSIS_FILE" 2>/dev/null || echo "false")
  if [[ "$analysis_exit_signal" == "true" ]]; then
    log_msg "INFO" "Completion signal detected at loop $i. Finishing early."
    exit 0
  fi

  log_msg "INFO" "Loop $i completed. Output: $output_file"

  if [[ "$i" -lt "$MAX_LOOPS" ]]; then
    sleep "$SLEEP_SECONDS"
  fi
done

log_msg "INFO" "Ralph Gemini loop finished"
