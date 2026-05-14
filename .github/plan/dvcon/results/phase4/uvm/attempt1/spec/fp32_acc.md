# Module Spec: `fp32_acc`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

6-stage pipelined float32 accumulator. Accepts float32 addend values one at a time and accumulates them into an internal register. Supports clear-to-zero and back-to-back accumulation with a forwarding mux that eliminates the RAW hazard between consecutive `acc_en` pulses spaced ≥ 4 cycles apart. Designed to meet 312.5 MHz on Kintex-7 `xc7k160tffg676-2`.

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset |
| `addend` | in | `float32_t` (32) | Value to add to the accumulator |
| `acc_en` | in | 1 | Strobe: start a new accumulate operation this cycle |
| `acc_clear` | in | 1 | Synchronous clear: reset accumulator to zero on next clock edge |
| `acc_out` | out | `float32_t` (32) | Current accumulated result (from Stage C register) |

## Pipeline Stages

```
Stage A0:   Exponent compare and operand selection
            (acc_larger_a0, decompose acc_fb and addend)
              │ posedge clk → *_r0 registers
Stage A0.5: Barrel-shift alignment only
            (shift smaller mantissa right by |exp_diff|)
              │ posedge clk → *_r05 registers
Stage A1:   Pre-compute arithmetic results
            (add_result, sub_big_minus_small, sub_small_minus_big, big_ge_small)
            All CARRY4 chains start from A0.5 FDREs
              │ posedge clk → *_r registers
Stage B1:   Mantissa MUX-select (no CARRY4)
            Select correct sum/diff based on signs and magnitude comparison
              │ posedge clk → sum_man_b1_r
Stage B2:   Normalise
            Leading-zero detection, shift, exponent adjustment
              │ posedge clk → partial_sum_r
Stage C:    Commit
            partial_sum_r → acc_reg (acc_out)
```

**Latency: 5 cycles** from `acc_en` to the result appearing in `acc_reg` (acc_out). Stage C fires 5 cycles after acc_en (`acc_en_d5`).

## Forwarding Mux (Back-to-Back Accumulation)

The feedback operand entering Stage A0 (`acc_fb`) is selected as:

```
acc_fb = acc_en_d5 ? partial_sum_r : acc_reg
```

When `acc_en_d5` is high (Stage C is about to fire), the most recent committed sum is in `partial_sum_r` rather than `acc_reg`. Using `partial_sum_r` directly eliminates the 1-cycle gap that would otherwise be required. This makes back-to-back accumulation safe for any `acc_en` spacing ≥ 4 cycles (matching the pipeline depth from the forwarding mux perspective).

The `dot_product_engine` round-robin scheme guarantees consecutive writes to the same accumulator are `VEC_LEN / NUM_ACCS_USED` ≥ 1 element periods apart, which for `VEC_LEN = 4, NUM = 4` is exactly 4 cycles.

## Synthesis Attributes

```systemverilog
(* max_fanout = 16 *) logic acc_larger_a0;
```

`acc_larger_a0` (exponent compare result from Stage A0) drives 64 downstream registers. Without the attribute, the CARRY4 chain has ~0.544 ns routing. The `max_fanout = 16` directive causes Vivado to replicate into ~4 CARRY4 copies, each driving ≤ 16 endpoints, reducing routing to ~0.150 ns per copy.

## Reset Behavior

- `acc_reg` resets to `32'h0000_0000` (float32 zero).
- `partial_sum_r` resets to zero.
- All delay pipeline registers (`acc_en_d1..5`) reset to 0.

`acc_clear` takes effect on the next posedge (registered clear into `acc_reg`). It can be asserted simultaneously with `acc_en`; in this case the clear takes priority.

## float32 Addition Algorithm

Uses a simplified floating-point add sufficient for small vector dot products where catastrophic cancellation is not expected:

1. Decompose both operands into sign, exponent, mantissa (with implicit leading 1).
2. Compare exponents; identify larger.
3. Shift smaller mantissa right by `|exp_diff|` for alignment.
4. Add or subtract mantissas (based on signs).
5. Normalize result (leading-zero shift, exponent adjust).

Subnormal inputs and NaN/Inf are not explicitly handled.
