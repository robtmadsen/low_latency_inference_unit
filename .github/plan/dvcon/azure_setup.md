# Azure Experiment Setup — Agentic UVM vs. Agentic cocotb

## 1. Experiment Overview

Two identical Azure VMs run in parallel, one per TB methodology. Each VM
receives the same stripped repo (DUT + spec only) and is driven by a Claude
Code agent with a methodology-specific prompt. The experiment runs
**without human intervention** once started.

**Independent variable:** TB methodology (UVM vs. cocotb)  
**Controlled variables:** VM compute, DUT, spec, agent model, prompt structure  
**Dependent variables:** Line coverage %, bugs found, token usage, wall-clock time,
files created, lines written

---

## 2. Phase Map

| Phase | DUT | Secret bugs | Goal | DVCon relevance |
|-------|-----|-------------|------|-----------------|
| **0** | — | — | Provision VMs; verify SSH + CLI access | Infrastructure |
| **1** | `itch_field_extract` (clean) | 0 | 100% line coverage, autonomous | Methodology proof |
| **2** | `itch_field_extract` (buggy) | ~2 | 100% coverage + bug report | Bug-finding capability |
| **3** | LLIU sub-set (TBD) | TBD | 100% coverage, larger scope | Scalability |
| **4** | Full LLIU DUT | ~10 (various types) | 100% coverage + full bug report | **DVCon paper** |

---

## 3. VM Specification (Common to All Phases)

| Property | Value |
|----------|-------|
| **SKU** | Standard_D2ads_v5 |
| **vCPUs** | 2 (AMD EPYC Milan) |
| **RAM** | 8 GB |
| **OS Disk** | 30 GB Premium SSD |
| **OS** | Ubuntu 22.04 LTS (Gen2) |
| **Count** | 2 (one per methodology) |
| **Region** | Same region (e.g. East US 2) |
| **Auto-shutdown** | Enabled — midnight UTC daily |

Both VMs are **identical in hardware and OS** so compute is not a confounding
variable. The only difference is the software stack installed and the prompt given
to the agent.

---

## 4. Software Stack (Common to All Phases)

### 4.1 System Packages

```bash
sudo apt-get update -qq
sudo apt-get install -y \
    git curl wget \
    g++ make \
    autoconf flex bison libfl-dev zlib1g-dev help2man \
    python3.12 python3.12-venv python3-pip \
    lcov  # for line coverage reporting
```

### 4.2 Verilator 5.046 (from source — apt version is too old)

```bash
git clone --depth 1 --branch v5.046 \
    https://github.com/verilator/verilator.git ~/verilator-src
cd ~/verilator-src
autoconf
./configure --prefix=/usr/local
make -j2
sudo make install
verilator --version  # verify: Verilator 5.046
```

### 4.3 Python Environment

```bash
python3.12 -m venv ~/venv
source ~/venv/bin/activate
pip install --upgrade pip
pip install cocotb numpy
```

### 4.4 Node.js (required by Claude Code CLI)

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version  # verify: v22.x
```

### 4.5 Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code
claude --version  # verify installation
```

Set the Anthropic API key (store in `~/.bashrc` and `/etc/environment`):

```bash
echo 'export ANTHROPIC_API_KEY=sk-ant-...' >> ~/.bashrc
sudo tee -a /etc/environment <<'EOF'
ANTHROPIC_API_KEY=sk-ant-...
EOF
```

### 4.6 UVM VM only — Accellera UVM source

```bash
git clone https://github.com/accellera-official/uvm-core.git ~/uvm-core
echo 'export UVM_HOME=$HOME/uvm-core/src' >> ~/.bashrc
sudo tee -a /etc/environment <<'EOF'
UVM_HOME=/home/azureuser/uvm-core/src
EOF
```

---

## 5. Phase 0 — VM Provisioning & CLI Access

**Goal:** Both Azure VMs are reachable from the developer's local machine
(macOS / VS Code) without a browser. Phase 0 is complete when a one-liner from
a local terminal drops into a shell on each VM and when VS Code can open a
Remote-SSH session.

### 5.1 Provision via Azure CLI

```bash
# Install Azure CLI (macOS)
brew update && brew install azure-cli
az login                          # opens browser once for auth

# Create resource group
# NOTE: eastus2 had capacity restrictions for all D/B-series SKUs on this subscription.
# westus2 with Standard_D2s_v5 worked fine.
az group create --name lliu-dvexp-w2 --location westus2

# Create vm-cocotb
az vm create \
  --resource-group lliu-dvexp-w2 \
  --name vm-cocotb \
  --image Ubuntu2204 \
  --size Standard_D2s_v5 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --output table

# Create vm-uvm (identical spec)
az vm create \
  --resource-group lliu-dvexp-w2 \
  --name vm-uvm \
  --image Ubuntu2204 \
  --size Standard_D2s_v5 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --output table

# Enable auto-shutdown at midnight UTC to conserve Azure credit
az vm auto-shutdown --resource-group lliu-dvexp-w2 --name vm-cocotb --time 0000
az vm auto-shutdown --resource-group lliu-dvexp-w2 --name vm-uvm   --time 0000
```

### 5.2 SSH Access

```bash
# Get public IPs
az vm list-ip-addresses --resource-group lliu-dvexp-w2 --output table

# ~/.ssh/config entries (already configured)
Host vm-cocotb
    HostName 20.3.110.144
    User azureuser
    IdentityFile ~/.ssh/id_rsa
    StrictHostKeyChecking no

Host vm-uvm
    HostName 20.236.28.45
    User azureuser
    IdentityFile ~/.ssh/id_rsa
    StrictHostKeyChecking no

# Test
ssh vm-cocotb "echo ok"
ssh vm-uvm   "echo ok"
```

### 5.3 VS Code Remote-SSH

1. Install the **Remote - SSH** extension in VS Code.
2. Open the Command Palette → **Remote-SSH: Connect to Host** → select
   `vm-cocotb` (or `vm-uvm`).
3. VS Code opens a full IDE session on the Azure VM. Terminals, file explorer,
   and extensions all run on the remote machine.

### 5.4 Phase 0 Completion Criteria

- [ ] Both VMs respond to `ssh vm-cocotb "verilator --version"` and `ssh vm-uvm "verilator --version"` with `Verilator 5.046`
- [ ] VS Code Remote-SSH opens on both VMs without password prompt
- [ ] `claude --version` returns successfully on both VMs
- [ ] Auto-shutdown confirmed enabled in Azure portal

---

## 6. Phase 1 — Clean DUT, itch_field_extract, 100% Coverage

**Goal:** Both VMs independently build a complete testbench from scratch,
achieve 100% line coverage of `itch_field_extract.sv`, and produce a
structured metrics report — with **zero human intervention** after the
agent is launched.

### 6.1 Experiment Repo Contents

Private GitHub repo `lliu-dv-experiment` with only:

```
rtl/
    lliu_pkg.sv               ← package dependency
    itch_field_extract.sv     ← DUT (clean, no injected bugs)
spec/
    itch_field_extract_spec.md  ← full DUT spec (see Appendix A)
```

No `tb/`, no `scripts/`, no `reports/`. The agent creates everything.

### 6.2 Autonomous Loop Design

#### Failure modes and mitigations

| Failure mode | Mitigation |
|---|---|
| Context window exhaustion (most common) | Outer loop re-launches; re-entry clause in prompt reads on-disk state before continuing |
| API rate-limit / 5xx error | Exponential backoff, up to 10 retries |
| `make` / simulation hangs indefinitely | Agent wraps each `make` subprocess with `timeout 300` — the claude session itself is never timed out externally |
| Claude Code session runs too long | `--max-turns 500` caps turns within a session; the 8 h wall-clock guard in `run_experiment.sh` is the emergency brake only |
| Claude Code pauses for a permission prompt | `--dangerously-skip-permissions` flag — never blocks |
| Agent declares "done" before 100% coverage | Outer loop checks `reports/coverage.txt`; if criterion unmet, re-launches with a continuation prompt that shows current coverage |
| Agent stuck in a bad loop (same error every attempt) | Max-attempts guard (10) + max wall-time guard (8 h); both abort and log |

**`run_experiment.sh`** (deploy to each VM, kept under `~/prompts/`):

```bash
#!/usr/bin/env bash
set -uo pipefail

METHODOLOGY=${1:?usage: run_experiment.sh [cocotb|uvm]}
PROMPT_FILE="$HOME/prompts/prompt_${METHODOLOGY}.txt"
CONT_PROMPT_FILE="$HOME/prompts/prompt_${METHODOLOGY}_continue.txt"
TELEMETRY_DIR="$HOME/experiment/telemetry"
REPORT="$HOME/experiment/reports/coverage.txt"

MAX_ATTEMPTS=10
MAX_WALL_HOURS=8

mkdir -p "$TELEMETRY_DIR" "$HOME/experiment/reports"
cd ~/experiment

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" | tee -a "$TELEMETRY_DIR/run.log"; }

log "=== Starting $METHODOLOGY experiment ==="
START_EPOCH=$(date +%s)
DEADLINE_EPOCH=$((START_EPOCH + MAX_WALL_HOURS * 3600))

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
    # continuation prompt (checks existing state first).
    if [ "$ATTEMPT" -eq 1 ]; then
        ACTIVE_PROMPT="$PROMPT_FILE"
    else
        # Inject current coverage into the continuation prompt
        CURRENT_COV="unknown"
        [ -f "$REPORT" ] && CURRENT_COV=$(cat "$REPORT" | grep -o '[0-9]*%' | tail -1 || echo "unknown")
        sed "s/{{CURRENT_COVERAGE}}/$CURRENT_COV/" "$CONT_PROMPT_FILE" > /tmp/prompt_active.txt
        ACTIVE_PROMPT="/tmp/prompt_active.txt"
    fi

    # Run the agent.
    #   --dangerously-skip-permissions  never pause for confirmation
    #   --max-turns 500                 allow long iterative sessions
    #   --output-format json            structured telemetry
    EXIT_CODE=0
    claude \
        --dangerously-skip-permissions \
        --max-turns 500 \
        --output-format json \
        --print "$(cat "$ACTIVE_PROMPT")" \
        2>> "$TELEMETRY_DIR/stderr_${ATTEMPT}.log" \
        | tee "$SESSION_JSON" \
        || EXIT_CODE=$?

    if [ "$EXIT_CODE" -ne 0 ]; then
        BACKOFF_SEC=$((15 * ATTEMPT))
        log "claude exited with code $EXIT_CODE. Backing off ${BACKOFF_SEC}s..."
        sleep "$BACKOFF_SEC"
        continue
    fi

    # --- Completion check ---
    if [ -f "$REPORT" ] && grep -q "100%" "$REPORT"; then
        END_EPOCH=$(date +%s)
        WALL_SECONDS=$((END_EPOCH - START_EPOCH))
        log "=== SUCCESS: 100% coverage in ${WALL_SECONDS}s after $ATTEMPT attempt(s) ==="

        TB_FILES=$(find tb/ -type f 2>/dev/null | wc -l || echo 0)
        TB_LINES=$(find tb/ -type f 2>/dev/null -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
        TOTAL_INPUT=$(jq -s '[.[].result.usage.input_tokens // 0] | add' "$TELEMETRY_DIR"/session_*.json 2>/dev/null || echo 0)
        TOTAL_OUTPUT=$(jq -s '[.[].result.usage.output_tokens // 0] | add' "$TELEMETRY_DIR"/session_*.json 2>/dev/null || echo 0)

        jq -n \
            --arg  method  "$METHODOLOGY" \
            --argjson wall   "$WALL_SECONDS" \
            --argjson att    "$ATTEMPT" \
            --argjson files  "$TB_FILES" \
            --argjson lines  "$TB_LINES" \
            --argjson inp    "$TOTAL_INPUT" \
            --argjson out    "$TOTAL_OUTPUT" \
            '{methodology:$method, wall_seconds:$wall, attempts:$att,
              tb_files_created:$files, tb_lines_written:$lines,
              total_input_tokens:$inp, total_output_tokens:$out}' \
            | tee "$TELEMETRY_DIR/summary_${METHODOLOGY}.json"
        break
    fi

    log "Coverage criterion not met after attempt $ATTEMPT. Relaunching..."
    sleep 5
done
```

**`prompt_<method>_continue.txt`** (re-entry variant, placed alongside the main prompt):

```
You are a verification engineer resuming a task that was interrupted.
Current line coverage: {{CURRENT_COVERAGE}}

Before doing anything else:
  1. Read all files in tb/ to understand what has already been built.
  2. Run `make -C tb/` to see the current build state.
  3. Check reports/coverage.txt for the current coverage percentage.
  4. Continue from the current state toward 100% line coverage.

All original requirements still apply (see below). Do not restart from
scratch — build on existing work.

--- ORIGINAL REQUIREMENTS ---
[paste full prompt body here]
```

Launch (fire-and-forget from local machine via `tmux`):

```bash
ssh vm-cocotb "tmux new-session -d -s exp 'bash ~/prompts/run_experiment.sh cocotb 2>&1 | tee ~/experiment/telemetry/outer.log'"
ssh vm-uvm    "tmux new-session -d -s exp 'bash ~/prompts/run_experiment.sh uvm    2>&1 | tee ~/experiment/telemetry/outer.log'"
```

Monitor from local machine at any time (non-blocking):

```bash
ssh vm-cocotb "tail -20 ~/experiment/telemetry/run.log && cat ~/experiment/reports/coverage.txt 2>/dev/null || echo 'no coverage yet'"
ssh vm-uvm    "tail -20 ~/experiment/telemetry/run.log && cat ~/experiment/reports/coverage.txt 2>/dev/null || echo 'no coverage yet'"
```

### 6.3 Agent Prompts

Both prompts are structurally identical. Only the methodology name changes.

**`prompt_cocotb.txt`:**

```
You are a verification engineer. Build a complete cocotb testbench for the
module `itch_field_extract` from scratch. This is a fully autonomous task.
Never stop to ask for human input — if something is ambiguous, make a
reasonable engineering decision and document it.

Read these files before writing any code:
  - rtl/itch_field_extract.sv        (the DUT)
  - rtl/lliu_pkg.sv                  (package dependency)
  - spec/itch_field_extract_spec.md  (full specification)

Requirements:
1. Use cocotb with Verilator 5.046 as the simulator backend.
2. Create a tb/ directory with a Makefile that compiles and runs all tests.
   Wrap every `make` or simulation invocation with `timeout 300` so a hung
   simulator cannot stall your session. Do NOT use `timeout` on any other
   command — only on `make` and direct simulator calls.
3. Write an independent Python reference model and a scoreboard that checks
   every output field on every transaction.
4. Achieve 100% line coverage of itch_field_extract.sv. Cover:
     - Valid Add Order messages ('A'/0x41), buy and sell sides
     - Non-Add-Order message types (fields_valid must remain 0)
     - Synchronous reset behaviour
     - Back-to-back valid messages (no idle cycles between)
     - msg_valid deasserted (fields_valid must remain 0)
5. Run Verilator with --coverage and write the coverage report to
   reports/coverage.txt. The file must contain "100%" for line coverage.
6. Throughout verification, if any test exposes output that contradicts the
   spec, document it in reports/bugs_found.md: which test, the symptom
   observed, and your root-cause hypothesis. If nothing is found, write
   reports/bugs_found.md with the text "No RTL bugs detected."
7. Write a structured summary to reports/phase1_summary.md: all tests run,
   pass/fail status, final coverage percentage.

Workflow loop — repeat until the exit criterion is met:
  a. Write or update testbench files.
  b. Run `timeout 300 make -C tb/ 2>&1`. Fix any compile or lint errors.
  c. Run `timeout 300 make -C tb/ test 2>&1`. Fix any test failures.
  d. Parse reports/coverage.txt for the current line coverage percentage.
  e. If coverage < 100%, identify uncovered lines, add targeted tests, and
     repeat from (a).
  f. When all tests pass and reports/coverage.txt shows 100% line coverage,
     write reports/phase1_summary.md and then STOP.

Exit criterion: ALL of the following must be true before stopping:
  - `make -C tb/ test` exits 0 (no test failures)
  - reports/coverage.txt contains the string "100%"
  - reports/bugs_found.md exists
  - reports/phase1_summary.md exists
```

**`prompt_uvm.txt`:** identical except:
- Replace "cocotb" with "UVM" throughout
- Requirement 1 becomes: "Use UVM with Verilator 5.046. UVM_HOME is set in
  the environment and points to the Accellera UVM source."
- Requirement 3 becomes: "Write a UVM scoreboard that checks every output field."

**The prompt never changes between phases.** The standing bug-report clause
(requirement 6) applies in every phase. The agent is never told whether
bugs exist or how many.

### 6.4 Phase 1 Completion Criteria

- [ ] `reports/coverage.txt` contains "100%" on both VMs
- [ ] `reports/phase1_summary.md` exists on both VMs with all tests listed
- [ ] `telemetry/summary_<method>.json` exists with wall time, token counts, file/line counts
- [ ] Both agents stopped autonomously (no human intervention after launch)

### 6.5 Phase 1 Metrics

| Metric | Source |
|--------|--------|
| Total input tokens | Sum `input_tokens` across `telemetry/session_*.json` |
| Total output tokens | Sum `output_tokens` across `telemetry/session_*.json` |
| Cache hit tokens | Sum `cache_read_input_tokens` |
| Wall-clock time (seconds) | `telemetry/summary_<method>.json → wall_seconds` |
| TB files created | `find tb/ -type f \| wc -l` |
| TB lines written | `find tb/ -type f \| xargs wc -l \| tail -1` |
| Number of agent attempts | `telemetry/summary_<method>.json → attempts` |
| Line coverage achieved | `reports/coverage.txt` |

---

## 7. Phase 2 — Bug-Injected itch_field_extract

**Goal:** Same autonomous loop as Phase 1, but the repo now includes
`rtl/bug-injected/itch_field_extract.sv` — a copy of the module with
~2 deliberate secret bugs. The agent must report any bugs discovered.

### 7.1 Repo Delta from Phase 1

The experimenter replaces `rtl/itch_field_extract.sv` with the buggy version
before the agents clone the repo. From the agent's perspective the repo looks
identical to Phase 1 — it only ever sees one copy of the module:

```
rtl/
    lliu_pkg.sv                    (unchanged)
    itch_field_extract.sv          (silently replaced with buggy version)
spec/
    itch_field_extract_spec.md     (unchanged)
```

The experimenter maintains a private `rtl/bug-injected/` reference folder
**outside the experiment repo** for ground-truth tracking. It never appears
in the repo the agent clones.

Bug types should match the mutation categories in
`reports/v1_dut/bug_detection.md` (e.g. wrong byte index, wrong comparison
operator, missing reset of one output, wrong endianness). ~2 bugs for Phase 2.

### 7.2 Prompt Change

None. The same prompt used in Phase 1 is used verbatim. The standing
bug-report clause (step 6) already instructs the agent to document any
discrepancies it finds. The agent is never told that bugs were injected.

### 7.3 Phase 2 Completion Criteria

Same as Phase 1, plus:
- [ ] `reports/bugs_found.md` exists on both VMs
- [ ] Bug kill rate recorded: (bugs found / bugs injected) per methodology

---

## 8. Phase 3 — Expanded LLIU Subset (TBD)

**Goal:** Scale the experiment to a larger DUT (multi-module subset of the
full LLIU) with secret bugs. Validates that the autonomous loop is robust
beyond a single leaf module.

DUT selection criteria (to be decided):
- 3–5 RTL modules with inter-module interfaces
- Includes at least one FIFO or handshake (backpressure path)
- Secret bugs should include at least one CDC or multi-cycle timing issue

This phase is defined after Phase 2 results are analysed.

---

## 9. Phase 4 — Full LLIU DUT (DVCon Paper)

**Goal:** Full `lliu_top` with ~10 secret bugs of heterogeneous types.
Identical autonomous setup. Results form the core data of the DVCon paper.

### 9.1 Bug Categories (~10 total, distributed across RTL modules)

| # | Type | Example location |
|---|------|-----------------|
| 1–2 | Off-by-one (field slice index) | `itch_field_extract`, `itch_parser` |
| 3–4 | Backpressure / valid-ready handshake | `output_buffer`, `axi4_lite_slave` |
| 5–6 | Reset omission (one output not cleared) | any registered module |
| 7 | Wrong endianness (byte swap) | `itch_field_extract` or `dot_product_engine` |
| 8 | CDC: missing synchroniser | cross-clock path in `lliu_top` |
| 9 | Arithmetic: accumulator overflow not cleared | `fp32_acc` |
| 10 | Control: wrong FSM state transition | `itch_parser` |

### 9.2 DVCon Metrics (both methodologies)

- Line coverage % of `lliu_top.sv` and all sub-modules
- Bug kill rate: bugs found / 10
- Wall-clock time to 100% coverage
- Total tokens (input + output) — proxy for agent "effort"
- TB files created and lines written — proxy for generated artifact size
- Number of autonomous restarts required

---

## 10. Telemetry Aggregation

```bash
# Total tokens for one methodology
jq -s '[.[].result.usage // empty] | {
    total_input:       map(.input_tokens)              | add,
    total_output:      map(.output_tokens)             | add,
    total_cache_read:  map(.cache_read_input_tokens)   | add,
    total_cache_write: map(.cache_creation_input_tokens) | add
}' telemetry/session_cocotb_*.json
```

Each `session_*.json` file is the raw output of one `claude --output-format json`
invocation. The `result.usage` object contains per-session token counts.

---

## 11. Extras — Future Measurement Ideas

### 11.1 Token Efficiency Curve

**Critique:** The telemetry aggregation above captures total tokens, but for a
DVCon paper the more compelling visualisation is the **token efficiency curve**:
cumulative tokens spent vs. coverage percentage achieved, plotted across all
attempts for each methodology.

**Recommendation:** Extend the `jq` aggregation to track tokens per attempt
alongside the coverage reading taken at the end of that attempt:

```bash
# After each claude session exits, append a row to a JSONL timeline file.
# Call this inside run_experiment.sh immediately after the completion check.
CURRENT_COV=$(grep -o '[0-9]*%' "$REPORT" 2>/dev/null | tail -1 || echo "0%")
SESSION_IN=$(jq '.result.usage.input_tokens // 0' "$SESSION_JSON")
SESSION_OUT=$(jq '.result.usage.output_tokens // 0' "$SESSION_JSON")

jq -n \
    --argjson attempt  "$ATTEMPT" \
    --arg     cov      "$CURRENT_COV" \
    --argjson inp      "$SESSION_IN" \
    --argjson out      "$SESSION_OUT" \
    '{attempt:$attempt, coverage_after:$cov,
      session_input_tokens:$inp, session_output_tokens:$out}' \
    >> "$TELEMETRY_DIR/token_curve_${METHODOLOGY}.jsonl"
```

The resulting `.jsonl` file has one row per outer-loop attempt and can be
plotted directly as a step curve: x = cumulative tokens, y = coverage %.

**Hypothesis:** UVM agents will likely show a large initial token spike
(generating the full environment skeleton: agent, sequencer, driver, monitor,
scoreboard, sequences) before the coverage needle moves at all. cocotb agents
are expected to produce a more linear burn: each iteration adds a small Python
test file and immediately runs it, so coverage and token spend rise in
proportion. If the hypothesis holds, the curve shapes alone — spike-then-plateau
vs. smooth ramp — become a qualitative result worth including in the paper
alongside the quantitative totals.

### 11.2 Simulation Wall Time

**Metric:** What fraction of the 8-hour budget was spent running simulation
vs. generating code?

**How to capture it:** Wrap each `timeout 300 make` call in `run_experiment.sh`
with `time`, and accumulate the real-time elapsed into a running counter:

```bash
SIM_SECONDS=0
SIM_START=$(date +%s)
timeout 300 make -C tb/ test 2>&1
SIM_END=$(date +%s)
SIM_SECONDS=$((SIM_SECONDS + SIM_END - SIM_START))
```

Write `sim_seconds` into `telemetry/summary_<method>.json` alongside
`wall_seconds`. The ratio `sim_seconds / wall_seconds` is then directly
comparable between methodologies.

**Hypothesis:** UVM agents spend a larger fraction of wall time generating
boilerplate (env, agent, sequencer, monitor) before the first successful
simulation run, resulting in a lower sim/wall ratio early in the session.
cocotb agents are expected to reach their first passing simulation faster,
so their sim/wall ratio should climb earlier — though it may plateau sooner
as coverage closure demands more targeted stimulus that takes longer to reason
about than to run.

---

## Appendix A — DUT Spec (`spec/itch_field_extract_spec.md`)

Place this file verbatim in the experiment repo.

```
Module: itch_field_extract
Language: SystemVerilog
Depends on: lliu_pkg (imported via `import lliu_pkg::*`)

Purpose:
    Registered field slicer for NASDAQ ITCH 5.0 Add Order messages.
    Extracts fields from a packed 36-byte message buffer and registers
    all outputs, adding exactly one pipeline stage of latency.
    Only asserts fields_valid when the message type is Add Order (0x41 = 'A').

Interface:
    Inputs:
        clk           : clock
        rst           : synchronous active-high reset
        msg_data      : logic [287:0]  — packed 36-byte message buffer.
                        Byte N = msg_data[(35-N)*8 +: 8]
        msg_valid     : logic          — asserted when msg_data holds a complete message

    Outputs (all registered — valid one cycle after msg_valid):
        message_type  : logic [7:0]   — byte 0 of message
        order_ref     : logic [63:0]  — bytes 11–18, big-endian
        side          : logic         — 1 = buy ('B'=0x42), 0 = sell
        price         : logic [31:0]  — bytes 32–35, big-endian
        stock         : logic [63:0]  — bytes 24–31, 8-byte ASCII ticker
        fields_valid  : logic         — 1 iff msg_valid AND message_type == 0x41

ITCH 5.0 Add Order message layout (36 bytes, all big-endian):
    Byte(s)  Field
    0        message_type (0x41 = Add Order)
    1–2      stock_locate
    3–4      tracking_number
    5–10     timestamp (nanoseconds since midnight)
    11–18    order_reference_number (uint64)
    19       buy_sell_indicator ('B' = 0x42 buy, 'S' = 0x53 sell)
    20–23    shares (uint32)
    24–31    stock (8-byte ASCII, right-padded with spaces 0x20)
    32–35    price (uint32, fixed-point: divide by 10000 for dollars)

Timing:
    - Outputs are registered: valid exactly 1 clock after msg_valid is asserted
    - Reset is synchronous active-high; all outputs go to 0 on rst

Filter behaviour:
    - If msg_valid=1 and message_type != 0x41: fields_valid=0 one cycle later,
      all other outputs reflect the non-Add-Order message bytes (don't-care)
    - If msg_valid=0: fields_valid=0 one cycle later

Coverage requirements (agent must satisfy all):
    - 100% line coverage of itch_field_extract.sv
    - Buy side exercised (buy_sell_indicator = 'B' = 0x42)
    - Sell side exercised (buy_sell_indicator != 0x42)
    - Non-Add-Order message type exercised (fields_valid stays 0)
    - Synchronous reset exercised (all outputs clear to 0)
    - Back-to-back valid messages (msg_valid high across consecutive cycles)
    - msg_valid=0 while msg_data changes (fields_valid stays 0)
```

