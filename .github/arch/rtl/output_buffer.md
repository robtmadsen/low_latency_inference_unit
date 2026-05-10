# Module Spec: `output_buffer`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

Single float32 register that latches the inference result from the dot-product engine and presents it for AXI4-Lite readout. Holds the value until the next inference result arrives. Asserts `result_ready` as a sticky flag once a valid result has been stored (cleared only by reset).

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset (`sys_rst`) |
| `result_in` | in | `float32_t` (32) | Inference result from `dot_product_engine` |
| `result_valid` | in | 1 | One-cycle strobe from DPE (`state == S_DONE`, combinational) |
| `result_out` | out | `float32_t` (32) | Latched result; held until next `result_valid` or reset |
| `result_ready` | out | 1 | Sticky flag: at least one valid result has been stored |

## Functional Description

```systemverilog
always_ff @(posedge clk) begin
    if (rst) begin
        result_out       <= '0;
        result_ready_reg <= 1'b0;
    end else if (result_valid) begin
        result_out       <= result_in;
        result_ready_reg <= 1'b1;
    end
end
assign result_ready = result_ready_reg;
```

- On `result_valid`: latch `result_in` into `result_out`; set `result_ready`.
- On `rst`: clear `result_out` to zero; clear `result_ready`.
- Otherwise: hold state.

## Timing

`result_valid` from the DPE is combinational (`state == S_DONE`). `output_buffer` samples it on the next posedge, so `result_out` and `result_ready` are updated one cycle after `dp_result_valid` is first seen.

`result_ready` is presented to `axi4_lite_slave` as `status_result_ready` (STATUS register bit 0). The host polls this bit to know when to read the RESULT register.

## Reset Behavior

Both `result_out` and `result_ready` clear to zero on `rst` (or `sys_rst`). A `ctrl_soft_reset` will therefore clear a previously latched result; the host must re-run inference or reload weights after soft-reset.

## Design Note

`output_buffer` is intentionally minimal — a single holding register — rather than a FIFO or double-buffer. The backpressure from `pipeline_hold` in `lliu_top` ensures the DPE cannot produce a new result before the sequencer has returned to `SEQ_IDLE`, so there is no risk of `result_valid` being asserted while a previous result is being read.
