#!/usr/bin/env bash
# run_experiment.sh — deploy to each Azure VM under ~/prompts/
# Usage: bash ~/prompts/run_experiment.sh [cocotb|uvm]
set -uo pipefail

METHODOLOGY=${1:?usage: run_experiment.sh [cocotb|uvm]}
PROMPT_FILE="$HOME/prompts/prompt_${METHODOLOGY}.txt"
CONT_PROMPT_FILE="$HOME/prompts/prompt_${METHODOLOGY}_continue.txt"
TELEMETRY_DIR="$HOME/experiment/telemetry"
REPORT="$HOME/experiment/reports/coverage.txt"

MAX_ATTEMPTS=10
MAX_WALL_HOURS=8

mkdir -p "$TELEMETRY_DIR" "$HOME/experiment/reports"
cd "$HOME/experiment"

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" | tee -a "$TELEMETRY_DIR/run.log"; }

log "=== Starting $METHODOLOGY experiment ==="
START_EPOCH=$(date +%s)
DEADLINE_EPOCH=$((START_EPOCH + MAX_WALL_HOURS * 3600))
SESSION_WALL_SECONDS=0  # §11.2: accumulated time inside claude sessions

ATTEMPT=0
while true; do
    ATTEMPT=$((ATTEMPT + 1))

    # --- Guard: max attempts ---
    if [ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]; then
        log "ABORT: MAX_ATTEMPTS=$MAX_ATTEMPTS reached without 100% coverage"
        exit 1
    fi

    # --- Guard: wall-clock deadline ---
    if [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]; then
        log "ABORT: ${MAX_WALL_HOURS}h wall-time limit reached"
        exit 1
    fi

    SESSION_JSON="$TELEMETRY_DIR/session_${METHODOLOGY}_$(date +%Y%m%dT%H%M%S).json"
    log "--- Attempt $ATTEMPT ---"

    # First attempt uses the full prompt; subsequent attempts use the
    # continuation prompt which reads existing state before continuing.
    if [ "$ATTEMPT" -eq 1 ]; then
        ACTIVE_PROMPT="$PROMPT_FILE"
    else
        # Inject current coverage into the continuation prompt
        CURRENT_COV="unknown"
        [ -f "$REPORT" ] && CURRENT_COV=$(grep -o '[0-9]*%' "$REPORT" | tail -1 || echo "unknown")
        sed "s/{{CURRENT_COVERAGE}}/$CURRENT_COV/" "$CONT_PROMPT_FILE" > /tmp/prompt_active.txt
        ACTIVE_PROMPT="/tmp/prompt_active.txt"
    fi

    # §11.2: time each claude session to measure agent wall time vs total wall time
    SESSION_START=$(date +%s)

    # Run the agent.
    #   --model                         primary model (default: claude-opus-4-6)
    #   --dangerously-skip-permissions  never pause for confirmation
    #   --max-turns 500                 allow long iterative sessions
    #   --output-format json            structured telemetry
    EXIT_CODE=0
    claude \
        --model claude-opus-4-6 \
        --dangerously-skip-permissions \
        --max-turns 500 \
        --output-format json \
        --print "$(cat "$ACTIVE_PROMPT")" \
        2>> "$TELEMETRY_DIR/stderr_${ATTEMPT}.log" \
        | tee "$SESSION_JSON" \
        || EXIT_CODE=$?

    SESSION_END=$(date +%s)
    SESSION_ELAPSED=$((SESSION_END - SESSION_START))
    SESSION_WALL_SECONDS=$((SESSION_WALL_SECONDS + SESSION_ELAPSED))

    if [ "$EXIT_CODE" -ne 0 ]; then
        BACKOFF_SEC=$((15 * ATTEMPT))
        log "claude exited with code $EXIT_CODE. Backing off ${BACKOFF_SEC}s..."
        sleep "$BACKOFF_SEC"
        continue
    fi

    # §11.1: append token curve row for this attempt
    CURRENT_COV_NOW=$(grep -o '[0-9]*%' "$REPORT" 2>/dev/null | tail -1 || echo "0%")
    SESSION_IN=$(jq  '.result.usage.input_tokens  // 0' "$SESSION_JSON" 2>/dev/null || echo 0)
    SESSION_OUT=$(jq '.result.usage.output_tokens // 0' "$SESSION_JSON" 2>/dev/null || echo 0)
    jq -n \
        --argjson attempt  "$ATTEMPT" \
        --arg     cov      "$CURRENT_COV_NOW" \
        --argjson inp      "$SESSION_IN" \
        --argjson out      "$SESSION_OUT" \
        '{attempt:$attempt, coverage_after:$cov,
          session_input_tokens:$inp, session_output_tokens:$out}' \
        >> "$TELEMETRY_DIR/token_curve_${METHODOLOGY}.jsonl"

    # --- Completion check ---
    if [ -f "$REPORT" ] && grep -q "100%" "$REPORT"; then
        END_EPOCH=$(date +%s)
        WALL_SECONDS=$((END_EPOCH - START_EPOCH))
        log "=== SUCCESS: 100% coverage in ${WALL_SECONDS}s after $ATTEMPT attempt(s) ==="

        TB_FILES=$(find tb/ -type f 2>/dev/null | wc -l || echo 0)
        TB_LINES=$(find tb/ -type f 2>/dev/null -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
        TOTAL_INPUT=$(jq  -s '[.[].result.usage.input_tokens  // 0] | add' \
                         "$TELEMETRY_DIR"/session_*.json 2>/dev/null || echo 0)
        TOTAL_OUTPUT=$(jq -s '[.[].result.usage.output_tokens // 0] | add' \
                         "$TELEMETRY_DIR"/session_*.json 2>/dev/null || echo 0)

        jq -n \
            --arg    method          "$METHODOLOGY" \
            --argjson wall           "$WALL_SECONDS" \
            --argjson session_wall   "$SESSION_WALL_SECONDS" \
            --argjson att            "$ATTEMPT" \
            --argjson files          "$TB_FILES" \
            --argjson lines          "$TB_LINES" \
            --argjson inp            "$TOTAL_INPUT" \
            --argjson out            "$TOTAL_OUTPUT" \
            '{methodology:$method,
              wall_seconds:$wall,
              session_wall_seconds:$session_wall,
              attempts:$att,
              tb_files_created:$files,
              tb_lines_written:$lines,
              total_input_tokens:$inp,
              total_output_tokens:$out}' \
            | tee "$TELEMETRY_DIR/summary_${METHODOLOGY}.json"
        break
    fi

    log "Coverage criterion not met after attempt $ATTEMPT. Relaunching..."
    sleep 5
done
