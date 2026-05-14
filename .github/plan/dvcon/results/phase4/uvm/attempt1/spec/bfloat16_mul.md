# Module Spec: `bfloat16_mul`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

2-stage pipelined bfloat16 multiplier. Takes two bfloat16 operands and produces a float32 product. Stage 1 uses the DSP48E1 P-register to implement the 8×8 mantissa multiply; Stage 2 normalizes the product and assembles the float32 result. Zero handling is explicit (either zero input → zero output).

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset |
| `a` | in | `bfloat16_t` (16) | First operand |
| `b` | in | `bfloat16_t` (16) | Second operand |
| `result` | out | `float32_t` (32) | Product, valid 2 cycles after inputs |

## Numeric Formats

### bfloat16 (input)

```
[15]    — sign
[14:7]  — exponent (8-bit, bias 127)
[6:0]   — mantissa (7 explicit bits; implicit leading 1 for normalized)
```

### float32 (output)

```
[31]    — sign
[30:23] — exponent (8-bit, bias 127)
[22:0]  — mantissa (23 explicit bits; implicit leading 1 for normalized)
```

## Pipeline Stages

### Stage 1 — DSP48E1 multiply (registers into P-register)

Computed combinationally, registered at posedge clk:

| Signal | Value |
|--------|-------|
| `a_man` | `{1'b1, a[6:0]}` if `a_exp != 0`; else `{1'b0, a[6:0]}` |
| `b_man` | `{1'b1, b[6:0]}` if `b_exp != 0`; else `{1'b0, b[6:0]}` |
| `man_product_r` | `a_man[7:0] × b_man[7:0]` → 16-bit product (DSP48E1 `use_dsp="yes"`) |
| `exp_sum_r` | `a_exp + b_exp − 127` (10-bit, zero-extended to detect under/overflow) |
| `r_sign_r` | `a_sign ^ b_sign` |
| `a_zero_r` | `a[14:0] == 0` |
| `b_zero_r` | `b[14:0] == 0` |

### Stage 2 — Normalize and assemble

Computed from Stage 1 registers, registered at posedge clk:

1. **Zero check**: if `a_zero_r || b_zero_r`, output `32'h0000_0000`.
2. **Normalization**: if `man_product_r[15]` is set (product overflowed into bit 15), shift right by 1 and increment exponent.
3. **Mantissa extraction**: upper 23 bits of normalized 14-bit explicit mantissa, zero-padded to 23 bits.
4. **Assemble**: `{r_sign_r, exp_sum_r[7:0], man_out[22:0]}`.

## Timing

**Latency: 2 cycles** from valid inputs to valid output.

Inputs (`a`, `b`) are presented combinationally (not registered) — the first register is inside Stage 1. The `dot_product_engine` accounts for this 2-cycle latency when scheduling `acc_sel` signal routing.

## Synthesis Note

The mantissa multiply is annotated `(* use_dsp = "yes" *)` on the `man_product_r` register to direct Vivado to map the 8×8 multiply to the DSP48E1 P-register, keeping the multiply in a single DSP tile and avoiding LUT-based 8-bit multipliers.
