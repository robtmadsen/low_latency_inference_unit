# AWS EC2 Backend Engineering — Problems & Solutions

Lessons learned from running Vivado ML Standard 2025.2 on AWS EC2 for LLIU v2.0
synthesis and place-and-route.

**Run dates:** April 8–9, 2026

**Instance history:**
- Initial runs on `r5.2xlarge` (64 GB RAM, 8 vCPUs) — OOM-prone at default thread counts.
- Upgraded to `c5.4xlarge` (62 GB RAM, 16 vCPUs) on April 9, 2026 to get more
  parallelism and headroom. Despite the upgrade, the `Cross Boundary and Area Optimization`
  hang persisted — the extra vCPUs caused Vivado to spawn *more* parallel synthesis workers,
  which actually increased peak memory consumption and did not reduce wall-clock time for
  the stuck phase. The root cause was the synthesis directive, not the instance size.

---

## Problem 1 — SSH sessions drop mid-run (exit code 255)

**Symptom:** Any `ssh lliu-par 'long command'` that runs longer than a few minutes exits
with code 255, killing the monitoring command. The Vivado nohup process itself survives,
but we lose visibility.

**Root cause:** The SSH control connection times out when there is no traffic on it for
several minutes. AWS security groups or NAT gateways silently drop idle TCP sessions,
and the client gets no RST — it just hangs until `ServerAliveInterval` fires and the
connection is declared dead.

**Solutions:**
- Add to `~/.ssh/config` under `Host lliu-par`:
  ```
  ServerAliveInterval 30
  ServerAliveCountMax 6
  ```
- For long polling loops, use a remote-side `while`/`sleep` so traffic flows continuously.
  A 120-second sleep inside a remote loop is long enough for NAT sessions to expire — use
  60 seconds or less.
- The gold standard: open a persistent `tmux` session on the EC2 instance and run all
  Vivado commands inside it. Reconnect at any time with `ssh lliu-par 'tmux attach'`.
  This completely decouples Vivado's lifetime from the SSH connection.

---

## Problem 2 — "Cross Boundary and Area Optimization" hangs for 8+ hours

**Symptom:** `synth_design` advances normally through parsing, elaboration, and initial
synthesis, then the log freezes at:
```
Start Cross Boundary and Area Optimization
```
The process stays at 104% CPU for hours with the log unchanged.

**Root cause:** `-flatten_hierarchy none` tells Vivado to synthesize each module
independently and then run a cross-module boundary analysis to share logic and remove
redundancy across hierarchy levels. At the scale of `lliu_top_v2` (17 modules, large
BRAM arrays in `order_book`, 8× DSP-heavy `lliu_core` instances), this pass has
super-linear runtime. It is the synthesis equivalent of a global LTO pass.

**Solutions (in order of preference):**
1. **Use `-flatten_hierarchy rebuilt`** (implemented in `syn/vivado_synth.tcl`).
   Vivado synthesizes flat internally (fast, skips cross-boundary sweep) then reconstructs
   the hierarchy for utilization reporting. Per-module resource counts are still visible.
   Quality is essentially equivalent to `none` for this design.
2. **Add `-directive RuntimeOptimized`** to `synth_design`. This is already applied and
   disables several secondary analysis passes in addition to speeding up synthesis.
3. **Add `-no_srlopt`**. Disables shift-register extraction — a secondary slow step on
   designs with large BRAM arrays (`order_book`). Not needed since all delay lines are
   explicit `always_ff` registers.

---

## Problem 3 — Memory pressure and OOM risk

**Symptom:** Main Vivado process peaks at ~24 GB. Four parallel `parallel_synth_helper`
worker processes each consume 2–3 GB. Total at peak: ~36 GB active + ~15 GB cached =
~51 GB of 62 GB. The instance has no swap. If a spike pushes past 62 GB the OOM killer
terminates Vivado silently — the SSH session drops with exit 255 and the log just stops.

**Root cause:** Parallel synthesis workers are launched automatically from `maxThreads`.
At `maxThreads 7` (the default for 16 vCPUs) the workers collectively consume ~14 GB,
pushing total usage past 62 GB.

**Solutions:**
- **Cap `maxThreads 4`** (implemented). Limits workers to ~3.3 GB collective overhead.
  Total stays under 28 GB active, well within the 62 GB limit.
- **Redirect `.Xil` temp files to `/dev/shm`** (`set ::env(XILINX_LOCALAPPDATA) /dev/shm`).
  Keeps temp writes off the root EBS volume and uses the instance store RAM. `/dev/shm`
  is 32 GB on a 62 GB instance. Monitor free space with `df -h /dev/shm` if suspicious.
- **Add swap** on EC2 before the next run:
  ```sh
  sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile
  sudo mkswap /swapfile && sudo swapon /swapfile
  ```
  16 GB of swap prevents OOM kills during transient peaks without impact to steady-state
  performance (Vivado is not swap-friendly but survival is better than silent termination).
- Long-term: an `r5.4xlarge` (128 GB) would eliminate memory pressure entirely at the
  cost of higher hourly rate. The `c5.4xlarge` upgrade (April 9) did not help because
  the issue was directive-driven compute, not memory — more cores meant more workers
  and higher peak RAM, not faster synthesis.

---

## Problem 4 — No way to recover a partial run

**Symptom:** If the SSH session drops mid-P&R or the instance is interrupted, there is no
checkpoint to resume from — the run must start over from RTL.

**Root cause:** The original `vivado_impl.tcl` was a monolithic script that only wrote
the final `lliu_routed.dcp`. Any interruption before that point meant a full restart.

**Solutions (implemented):**
- **Split into `vivado_synth.tcl` + `vivado_par.tcl`**. Synthesis writes `lliu_synth.dcp`,
  then P&R reads it. A crash in P&R means only P&R needs to repeat (~40 min) rather than
  the full flow (~3–5 hr).
- **Intermediate checkpoints in `vivado_par.tcl`**:
  - `lliu_opted.dcp` — after `opt_design`
  - `lliu_placed.dcp` — after `place_design`
  - `lliu_physopt.dcp` — after first `phys_opt_design`
  Each checkpoint can be opened with `open_checkpoint` and the remaining steps run from
  there. Add a recovery script if needed.
- **Use tmux** so a dropped laptop SSH never interrupts the remote Vivado process.

---

## Problem 5 — `opt_design` runs expensive cross-boundary pass

**Symptom:** After `synth_design` completes, `opt_design` (implementation step 1) stalls
in a cross-boundary optimization sweep — the same failure mode as Problem 2 but inside
the implementation phase.

**Root cause:** Default `opt_design` (no directive) runs `Explore` quality level, which
includes cross-boundary retiming and area optimization equivalent to the synthesis-side
`-flatten_hierarchy none` sweep.

**Solution (implemented in `vivado_par.tcl`):**
```tcl
opt_design -directive RuntimeOptimized
```
`RuntimeOptimized` skips cross-boundary analysis in opt. If WNS after first P&R pass is
worse than −0.3 ns, escalate to `-directive Explore` for a targeted re-run.

---

## Problem 6 — Single combined script is hard to PR incrementally

**Symptom:** The entire synthesis + P&R flow was one `vivado_impl.tcl`. Any change to one
phase (e.g., adjusting a placement directive) required a full re-run and a large PR.

**Solution (implemented):**

| Script | Artifact | PR-able milestone |
|--------|----------|-------------------|
| `vivado_synth.tcl` | `lliu_synth.dcp`, `utilization_synth.txt` | RTL compiles, resource counts look correct |
| `vivado_par.tcl` | `lliu_routed.dcp`, `timing.txt`, `utilization.txt`, `cdc.txt`, `lliu.bit` | Timing closed, CDC clean |

Each step runs independently and produces reviewable artifacts (utilization, timing summary)
that can be committed and discussed before the next step begins.

---

## Problem 7 — Cannot tell if Vivado is stuck vs. working slowly

**Symptom:** The log line count stops advancing for long periods. It is impossible to tell
whether Vivado is making progress internally (no log output for a slow pass) or is truly
stuck (deadlock, OOM near-miss, or kernel scheduling starvation).

**Solutions:**
- **Check CPU %** with `ps aux | grep vivado`. If the main process is ≥ 50% CPU it is
  working. If it drops to < 5% consistently for >10 minutes, suspect OOM pressure or
  a deadlock in the parallel workers.
- **Check memory headroom** with `free -h`. If `available` drops below 4 GB the system
  is likely paging and Vivado runtime will expand dramatically.
- **Check disk** with `df -h /dev/root` and `df -h /dev/shm`. A full root disk silently
  kills Vivado's ability to write checkpoints.
- **Log timestamp** with `stat -c "%y" syn/reports/vivado_synth.log`. If the file mtime
  is advancing the log is still being written (batch-flushed) even if the line count looks
  the same.

---

## Recommended Workflow for Future Runs

1. **Open a tmux session on EC2 before starting anything:**
   ```sh
   ssh lliu-par 'tmux new -s vivado' 
   # or to re-attach:
   ssh lliu-par 'tmux attach -t vivado'
   ```
2. **Add swap** before the run if not already present (see Problem 3).
3. **Run synthesis first, review artifacts, then kick off P&R:**
   ```sh
   # from inside tmux on EC2
   cd ~/low_latency_inference_unit
   /opt/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source syn/vivado_synth.tcl \
     2>&1 | tee syn/reports/vivado_synth.log
   # review utilization_synth.txt
   /opt/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source syn/vivado_par.tcl \
     2>&1 | tee syn/reports/vivado_par.log
   ```
4. **Never kill a Vivado run without explicit user instruction.** Report status and
   recommend — do not act.
5. **Pull artifacts after each stage completes** and commit to a branch before moving
   to the next stage.
