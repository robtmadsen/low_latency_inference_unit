# How to Monitor a Vivado Synthesis Run on EC2

All commands run from your local machine via `ssh lliu-par`.

---

## 1. Is Vivado still running?

```sh
ssh lliu-par 'ps aux | grep vivado | grep -v grep'
```

If you see a `vivado` process, it's still running. No output means it finished (or crashed).

## 2. Tail the log

```sh
ssh lliu-par 'tail -30 ~/low_latency_inference_unit/syn/reports/vivado.log'
```

Or for the timestamped synthesis-only log:

```sh
ssh lliu-par 'ls -lt ~/low_latency_inference_unit/syn/reports/vivado_synth_*.log | head -1'
ssh lliu-par 'tail -30 ~/low_latency_inference_unit/syn/reports/vivado_synth_*.log'
```

Look for phase names like `Synthesis`, `Cross Boundary`, `Technology Mapping`, `Rebuilding User Hierarchy`. If the timestamp on the last line is recent, synthesis is making progress.

## 3. Check log freshness (is it stuck?)

```sh
ssh lliu-par 'stat -c "%y %s" ~/low_latency_inference_unit/syn/reports/vivado.log'
```

Compare the modification time to `date`. If the log hasn't been updated in 30+ minutes, the run may be stalled.

## 4. CPU and memory footprint

```sh
ssh lliu-par 'ps -p $(pgrep -f vivado | head -1) -o pid,pcpu,pmem,etime,comm'
```

- `%CPU` near 0 for a long time → likely stuck
- `%MEM` growing steadily → still working (synthesis is memory-hungry)

For a broader view:

```sh
ssh lliu-par 'free -h && echo "---" && top -bn1 | head -15'
```

## 5. Disk usage

```sh
ssh lliu-par 'df -h / && echo "---" && du -sh ~/low_latency_inference_unit/.Xil 2>/dev/null'
```

A growing `.Xil` directory means Vivado is actively writing scratch data.

## 6. Check for generated reports / checkpoints

```sh
ssh lliu-par 'ls -lhtr ~/low_latency_inference_unit/syn/reports/'
ssh lliu-par 'ls -lhtr ~/low_latency_inference_unit/syn/*.dcp 2>/dev/null'
```

Reports and `.dcp` checkpoints appear as each phase completes:

| File | Meaning |
|------|---------|
| `utilization_synth.txt` | Post-synthesis complete |
| `lliu_synth.dcp` | Synthesis checkpoint saved |
| `utilization.txt` | Post-route complete |
| `timing.txt` | Post-route timing analysis done |
| `lliu_routed.dcp` | Routed checkpoint saved |
| `lliu.bit` | Bitstream generated — run is done |

## 7. Quick one-liner status check

```sh
ssh lliu-par 'echo "=== Process ===" && ps aux | grep "[v]ivado" && echo "=== Log tail ===" && tail -5 ~/low_latency_inference_unit/syn/reports/vivado.log 2>/dev/null && echo "=== Reports ===" && ls -lhtr ~/low_latency_inference_unit/syn/reports/ 2>/dev/null && echo "=== Disk ===" && df -h /'
```

## 8. CRITICAL WARNINGS to watch for

After the run, grep for blocking issues:

```sh
ssh lliu-par 'grep -c "CRITICAL WARNING" ~/low_latency_inference_unit/syn/reports/vivado.log'
ssh lliu-par 'grep "CRITICAL WARNING" ~/low_latency_inference_unit/syn/reports/vivado.log'
```

Key ones:
- **`Synth 8-6859`** — multi-driven net (RTL bug, must fix)
- **`Synth 8-7052`** — BRAM without output register (timing advisory, usually OK)

## 9. Did timing close?

```sh
ssh lliu-par 'grep -A2 "WNS\|WHS\|Design Timing Summary" ~/low_latency_inference_unit/syn/reports/timing.txt'
```

- **WNS > 0** and **WHS > 0** → timing met at 300 MHz
- **WNS < 0** → setup violation, need to investigate critical path
