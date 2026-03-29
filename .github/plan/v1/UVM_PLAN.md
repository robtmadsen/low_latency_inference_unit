# UVM Verification Plan

> **Architecture:** [UVM_ARCH.md](../arch/UVM_ARCH.md) · **Master plan:** [MASTER_PLAN.md](MASTER_PLAN.md) · **Spec:** [SPEC.md](../arch/SPEC.md)

Each phase ends with a functional commit. UVM development can proceed in parallel with cocotb, but both depend on RTL being available for the target module.

**Prerequisite:** RTL Phase 6 (lliu_top) should be complete before Phase 1 begins. Unlike cocotb, UVM infrastructure (agents, env, sequences) is built as an integrated unit targeting the system level first.

---

## Phase 1: Testbench Skeleton + Compile

**Goal:** UVM testbench compiles and elaborates with Verilator. DUT instantiated, clock/reset running. No stimulus yet.

### RTL Dependency: RTL Phase 6 (lliu_top)

### Steps

1. Create directory structure per [UVM_ARCH.md](../arch/UVM_ARCH.md): `tb/uvm/agents/`, `env/`, `sequences/`, `tests/`, `sva/`, `golden_model/`, `perf/`
2. Implement `tb_top.sv`
   - Clock generator: 300 MHz (3.33ns period)
   - Reset: active-high synchronous, held for 10 cycles
   - DUT instantiation: `lliu_top` with AXI4-Stream and AXI4-Lite interfaces
   - Interface instances: `axi4_stream_if`, `axi4_lite_if` (virtual interface types)
   - `uvm_config_db#(virtual ...)::set()` for both interfaces
   - `run_test()` call
3. Define interface files
   - `axi4_stream_if.sv`: `tdata[63:0]`, `tvalid`, `tready`, `tlast`, clocking blocks for driver/monitor
   - `axi4_lite_if.sv`: full AXI4-Lite signal set, clocking blocks
4. Implement `lliu_base_test.sv`
   - Extends `uvm_test`
   - Builds `lliu_env` (empty shell for now)
   - `build_phase`, `run_phase` with timeout
5. Implement `lliu_env.sv` — empty shell
   - Extends `uvm_env`
   - Placeholder `build_phase` and `connect_phase`
6. Create `Makefile`
   - `SIM=verilator` and `SIM=vcs` targets
   - Compile: RTL + UVM package + TB files
   - `make SIM=verilator compile` succeeds
   - `make SIM=verilator run TEST=lliu_base_test` starts and exits cleanly (no stimulus, no errors)

### Commit: `uvm: testbench skeleton, tb_top, interfaces, base test, Makefile`

**Files:**
```
tb/uvm/tb_top.sv
tb/uvm/axi4_stream_if.sv
tb/uvm/axi4_lite_if.sv
tb/uvm/env/lliu_env.sv
tb/uvm/tests/lliu_base_test.sv
tb/uvm/Makefile
```

---

## Phase 2: AXI4-Stream Agent

**Goal:** Fully functional AXI4-Stream UVM agent: driver, monitor, sequencer. Can send and observe AXI4-Stream transactions.

### Steps

1. Define `axi4_stream_transaction.sv`
   - Extends `uvm_sequence_item`
   - Fields: `rand bit [63:0] tdata[]` (dynamic array of beats), `bit tlast`
   - Constraints: reasonable max length
   - `do_copy()`, `do_compare()`, `convert2string()`
2. Implement `axi4_stream_driver.sv`
   - Extends `uvm_driver`
   - Gets virtual interface from config_db
   - `run_phase`: gets next item from sequencer, drives beats onto interface, respects `tready`
3. Implement `axi4_stream_monitor.sv`
   - Extends `uvm_monitor`
   - Passive: samples `tdata` when `tvalid & tready`
   - Accumulates beats until `tlast`
   - Writes complete transaction to analysis port
4. Implement `axi4_stream_sequencer.sv`
   - Extends `uvm_sequencer`
   - Parameterized on transaction type
5. Implement `axi4_stream_agent.sv`
   - Extends `uvm_agent`
   - Builds driver, monitor, sequencer
   - Connects driver to sequencer in ACTIVE mode
   - Monitor always active
6. Integrate agent into `lliu_env.sv`
7. Write a trivial directed sequence that sends one 8-byte beat
8. Verify: `make SIM=verilator run TEST=lliu_base_test` — agent sends one beat, monitor captures it, test completes

### Commit: `uvm: AXI4-Stream agent (driver, monitor, sequencer)`

**Files:**
```
tb/uvm/agents/axi4_stream_agent/axi4_stream_transaction.sv
tb/uvm/agents/axi4_stream_agent/axi4_stream_driver.sv
tb/uvm/agents/axi4_stream_agent/axi4_stream_monitor.sv
tb/uvm/agents/axi4_stream_agent/axi4_stream_sequencer.sv
tb/uvm/agents/axi4_stream_agent/axi4_stream_agent.sv
tb/uvm/env/lliu_env.sv (updated)
```

---

## Phase 3: AXI4-Lite Agent

**Goal:** Fully functional AXI4-Lite UVM agent for control plane access.

### Steps

1. Define `axi4_lite_transaction.sv`
   - Fields: `rand bit [31:0] addr`, `rand bit [31:0] data`, `rand bit [3:0] wstrb`, `bit is_write`
   - `do_copy()`, `do_compare()`, `convert2string()`
2. Implement `axi4_lite_driver.sv`
   - Write path: AW channel → W channel → wait B response
   - Read path: AR channel → wait R response, capture rdata
   - Handles handshakes correctly (no combinational dependency between channels)
3. Implement `axi4_lite_monitor.sv`
   - Passive: captures both write and read transactions
   - Analysis port output
4. Implement `axi4_lite_sequencer.sv` and `axi4_lite_agent.sv`
5. Integrate into `lliu_env.sv`
6. Implement `sequences/weight_load_seq.sv`
   - Loads a known weight vector via AXI4-Lite writes to weight_mem register map
   - Parameterized weight values
7. Verify: `make SIM=verilator run TEST=lliu_base_test` — weight load sequence writes to DUT, no errors

### Commit: `uvm: AXI4-Lite agent, weight load sequence`

**Files:**
```
tb/uvm/agents/axi4_lite_agent/axi4_lite_transaction.sv
tb/uvm/agents/axi4_lite_agent/axi4_lite_driver.sv
tb/uvm/agents/axi4_lite_agent/axi4_lite_monitor.sv
tb/uvm/agents/axi4_lite_agent/axi4_lite_sequencer.sv
tb/uvm/agents/axi4_lite_agent/axi4_lite_agent.sv
tb/uvm/sequences/weight_load_seq.sv
tb/uvm/env/lliu_env.sv (updated)
```

---

## Phase 4: Golden Model + Scoreboard

**Goal:** DPI-C bridge to Python golden model. Scoreboard compares DUT output to golden model prediction.

### Steps

1. Implement `golden_model/dpi_bridge.c`
   - DPI-C export function: `int dpi_golden_inference(const svOpenArrayHandle features, const svOpenArrayHandle weights, double* result)`
   - Embeds Python interpreter (`Py_Initialize`)
   - Calls `golden_model.py` functions via Python C API
   - Returns float32 result
2. Verify `golden_model/golden_model.py` is the same file used by cocotb (symlink or shared path)
3. Implement `env/lliu_predictor.sv`
   - Extends `uvm_subscriber` (subscribes to AXI4-Stream monitor analysis port)
   - On each complete ITCH transaction received:
     - Extracts expected fields using DPI-C call to golden model parse
     - Computes expected features via DPI-C
     - Computes expected inference result via DPI-C
     - Sends expected result to scoreboard
4. Implement `env/lliu_scoreboard.sv`
   - Extends `uvm_scoreboard`
   - Two analysis FIFOs: expected (from predictor) and actual (from AXI4-Lite monitor on result reads)
   - Compares each pair: exact float32 match required (deterministic pipeline)
   - Reports: total compared, total mismatches, first mismatch details
5. Integrate predictor and scoreboard into `lliu_env.sv`
6. Update Makefile: link `dpi_bridge.c`, set `PYTHONHOME`, add `libpython3.12` flags
7. Verify: compile with DPI-C succeeds, `lliu_base_test` runs with scoreboard (no transactions yet, just no errors)

### Commit: `uvm: DPI-C golden model bridge, predictor, scoreboard`

**Files:**
```
tb/uvm/golden_model/dpi_bridge.c
tb/uvm/golden_model/golden_model.py (shared with cocotb)
tb/uvm/env/lliu_predictor.sv
tb/uvm/env/lliu_scoreboard.sv
tb/uvm/env/lliu_env.sv (updated)
tb/uvm/Makefile (updated)
```

---

## Phase 5: Smoke Test

**Goal:** First end-to-end UVM test. One Add Order in, one inference result out, scoreboard passes.

### Steps

1. Implement `sequences/itch_replay_seq.sv` — minimal version
   - For now: constructs a single valid Add Order message as raw bytes
   - Packetizes into AXI4-Stream beats
   - Sends via sequencer
2. Implement `tests/lliu_smoke_test.sv`
   - Extends `lliu_base_test`
   - `run_phase`:
     1. Start `weight_load_seq` on AXI4-Lite sequencer (known weights)
     2. Start single-message `itch_replay_seq` on AXI4-Stream sequencer
     3. Wait for inference completion (poll result register via AXI4-Lite read sequence)
     4. Scoreboard auto-checks via predictor
   - `check_phase`: verify scoreboard has 1 comparison, 0 mismatches
3. Verify: `make SIM=verilator run TEST=lliu_smoke_test` — passes with scoreboard match

### Commit: `uvm: smoke test — single Add Order end-to-end with scoreboard`

**Files:**
```
tb/uvm/sequences/itch_replay_seq.sv (minimal)
tb/uvm/tests/lliu_smoke_test.sv
```

---

## Phase 6: Real Data Replay

**Goal:** Replay actual NASDAQ ITCH sample data through the UVM testbench.

### Steps

1. Complete `sequences/itch_replay_seq.sv`
   - Uses DPI-C `$fopen` / `$fread` to read `data/tvagg_sample.bin`
   - Parses ITCH framing: 2-byte big-endian length → payload
   - Packetizes each message into AXI4-Stream transactions
   - Configurable: max messages, filter by type
2. Implement `tests/lliu_replay_test.sv`
   - Extends `lliu_base_test`
   - Loads weights, then replays sample file
   - Scoreboard checks every Add Order inference result
   - Reports total messages replayed, total checked, mismatches
3. Verify: `make SIM=verilator run TEST=lliu_replay_test` — passes with real data

### Commit: `uvm: real ITCH data replay test`

**Files:**
```
tb/uvm/sequences/itch_replay_seq.sv (complete)
tb/uvm/tests/lliu_replay_test.sv
```

---

## Phase 7: Constrained-Random Sequence

**Goal:** Random valid Add Order generation with seed control.

### Steps

1. Implement `sequences/itch_random_seq.sv`
   - Extends `uvm_sequence`
   - `rand int unsigned num_messages` (default: 100)
   - Each iteration: randomize Add Order fields within constraints
     - Price: 1–999999 (covers penny to large cap)
     - Side: 50/50 buy/sell
     - Order ref: unique incrementing
   - Encode as ITCH binary, packetize, send
2. Update `lliu_base_test` or create `lliu_random_test.sv`
   - Loads weights, runs `itch_random_seq` with 100 messages, scoreboard checks all
3. Verify: `make SIM=verilator run TEST=lliu_random_test` — passes

### Commit: `uvm: constrained-random ITCH sequence`

**Files:**
```
tb/uvm/sequences/itch_random_seq.sv
tb/uvm/tests/lliu_random_test.sv (or integrated into base)
```

---

## Phase 8: Functional Coverage

**Goal:** Coverage model tracks verification progress across message types, prices, and sides.

### Steps

1. Implement `env/lliu_coverage.sv`
   - Extends `uvm_subscriber` (subscribes to AXI4-Stream monitor)
   - Covergroups:
     - `msg_type_cg`: bins for 'A' (Add Order) and other observed types
     - `price_range_cg`: bins for penny (1–99), dollar (100–9999), large (10000+)
     - `side_cg`: buy, sell
     - `cross_cg`: price_range × side
   - `sample()` called on every transaction from monitor
2. Integrate into `lliu_env.sv`
3. Run `lliu_random_test` with 1000 messages, check coverage report in sim log
4. Verify coverage percentages are printed at end of simulation

### Commit: `uvm: functional coverage model`

**Files:**
```
tb/uvm/env/lliu_coverage.sv
tb/uvm/env/lliu_env.sv (updated)
```

---

## Phase 9: SVA Bind Files

**Goal:** Protocol compliance and FSM safety assertions bound to DUT.

### Steps

1. Implement `sva/axi4_stream_sva.sv`
   - `tvalid` must not deassert without handshake (`tvalid && !tready |=> tvalid`)
   - `tdata` must be stable while `tvalid && !tready`
   - `tlast` framing: `tlast` asserted exactly once per transaction
2. Implement `sva/axi4_lite_sva.sv`
   - Write channels: AWVALID/WVALID stability rules
   - Read channel: ARVALID stability
   - Response ordering
3. Implement `sva/parser_sva.sv`
   - FSM state one-hot (if applicable)
   - Latency assertion: `fields_valid` within 5 cycles of input handshake
   - No stuck state: FSM must leave non-IDLE state within bounded cycles
4. Implement `sva/dot_product_sva.sv`
   - `result_valid` within bounded cycles of `start`
   - No `result_valid` without preceding `start`
   - Accumulator clears on new computation
5. Bind all in `tb_top.sv` using `bind` statements
6. **Note:** Full SVA evaluation requires VCS. Verilator supports a subset — test what works, document the rest as VCS-only.
7. Verify: `make SIM=verilator run TEST=lliu_replay_test` — no assertion failures (subset that Verilator supports)

### Commit: `uvm: SVA bind files for protocol compliance and FSM safety`

**Files:**
```
tb/uvm/sva/axi4_stream_sva.sv
tb/uvm/sva/axi4_lite_sva.sv
tb/uvm/sva/parser_sva.sv
tb/uvm/sva/dot_product_sva.sv
tb/uvm/tb_top.sv (updated with bind statements)
```

---

## Phase 10: Stress + Error Injection

**Goal:** Backpressure and malformed message handling.

### Steps

1. Implement `sequences/backpressure_seq.sv`
   - Controls `tready` on the AXI4-Stream interface with configurable patterns:
     - Always ready
     - Periodic: N cycles ready, M cycles stalled
     - Random: per-cycle `tready` with configurable probability
   - Runs concurrently with ingress sequences via `fork`
2. Implement `sequences/itch_error_seq.sv`
   - `generate_truncated()`: message shorter than length field declares
   - `generate_bad_type()`: invalid message type byte
   - `generate_oversized()`: exceeds max ITCH message length
   - Each followed by a valid Add Order to test recovery
3. Implement `tests/lliu_stress_test.sv`
   - Runs `itch_random_seq` (1000 msgs) with concurrent `backpressure_seq` (periodic stall)
   - Scoreboard checks all — no data loss under backpressure
4. Implement `tests/lliu_error_test.sv`
   - Runs `itch_error_seq`, verifies:
     - Parser doesn't hang (timeout assertion)
     - Valid messages after errors still parse correctly
     - Scoreboard matches on the valid messages
5. Verify both tests pass

### Commit: `uvm: backpressure sequences, error injection, stress + error tests`

**Files:**
```
tb/uvm/sequences/backpressure_seq.sv
tb/uvm/sequences/itch_error_seq.sv
tb/uvm/tests/lliu_stress_test.sv
tb/uvm/tests/lliu_error_test.sv
```

---

## Phase 11: Latency Profiling

**Goal:** Cycle-accurate latency measurement within UVM.

### Steps

1. Implement `perf/lliu_latency_monitor.sv`
   - Extends `uvm_monitor` (or standalone module bound to DUT)
   - Timestamps: cycle count at AXI4-Stream `tvalid & tready` (ingress) and `result_valid` (egress)
   - Computes per-message latency, stores in queue
   - `report_phase`:
     - Min / max / mean / median
     - p50, p99, p99.9
     - Stddev (jitter)
     - Prints formatted table
2. Integrate into `lliu_env.sv`
3. Run `lliu_replay_test` — verify latency report appears in sim log
4. Run `lliu_stress_test` — verify latency under backpressure is reported

### Commit: `uvm: cycle-accurate latency + jitter profiling monitor`

**Files:**
```
tb/uvm/perf/lliu_latency_monitor.sv
tb/uvm/env/lliu_env.sv (updated)
```

---

## Phase 12: CI Workflow

**Goal:** GitHub Actions runs UVM regression via Verilator on every push and PR.

### Steps

1. Create `.github/workflows/uvm.yml`
   - Trigger: push to `main`, all PRs
   - Runner: `ubuntu-latest`
   - Steps:
     1. Checkout
     2. Cache Verilator build
     3. Build Verilator 5.0+ if not cached
     4. Setup Python 3.12 (for DPI-C golden model)
     5. `pip install numpy`
     6. `make -C tb/uvm SIM=verilator run TEST=lliu_smoke_test`
     7. `make -C tb/uvm SIM=verilator run TEST=lliu_replay_test`
     8. `make -C tb/uvm SIM=verilator run TEST=lliu_stress_test`
     9. Upload coverage and latency reports as artifacts
2. Document VCS-only targets in Makefile help text (`make help`)
3. Verify workflow passes on push

### Commit: `ci: add UVM GitHub Actions workflow`

**Files:**
```
.github/workflows/uvm.yml
```

---

## Summary

| Phase | Commit Message | RTL Dep | Key Deliverable |
|-------|---------------|---------|-----------------|
| 1 | `uvm: testbench skeleton, tb_top, interfaces, base test, Makefile` | RTL P6 | Compiling TB, DUT instantiated |
| 2 | `uvm: AXI4-Stream agent (driver, monitor, sequencer)` | RTL P6 | Stream BFM |
| 3 | `uvm: AXI4-Lite agent, weight load sequence` | RTL P6 | Control plane BFM |
| 4 | `uvm: DPI-C golden model bridge, predictor, scoreboard` | RTL P6 | Checking infrastructure |
| 5 | `uvm: smoke test — single Add Order end-to-end with scoreboard` | RTL P6 | First passing end-to-end test |
| 6 | `uvm: real ITCH data replay test` | RTL P6 | Real data verification |
| 7 | `uvm: constrained-random ITCH sequence` | RTL P6 | Random stimulus |
| 8 | `uvm: functional coverage model` | RTL P6 | Coverage tracking |
| 9 | `uvm: SVA bind files for protocol compliance and FSM safety` | RTL P6 | Assertions |
| 10 | `uvm: backpressure sequences, error injection, stress + error tests` | RTL P6 | Stress testing |
| 11 | `uvm: cycle-accurate latency + jitter profiling monitor` | RTL P6 | Performance measurement |
| 12 | `ci: add UVM GitHub Actions workflow` | All | CI pipeline |

**After Phase 12, UVM verification is complete with CI.**
