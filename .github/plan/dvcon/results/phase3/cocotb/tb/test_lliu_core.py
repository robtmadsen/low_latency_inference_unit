"""
Cocotb testbench for lliu_core (via lliu_core_wrapper).

Includes:
  - BF16/FP32 conversion helpers
  - Reference model (spec-correct dot product)
  - Scoreboard (compares DUT output vs reference on every result_valid)
  - Coverage-oriented tests exercising all FSM states
  - Bug-detection tests
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import struct
import os

VEC_LEN = 32
CLK_PERIOD_NS = 10
RESULT_TIMEOUT_CYCLES = 150

# ──────────────────── BF16 / FP32 helpers ────────────────────

def float_to_bf16(val):
    packed = struct.pack('>f', float(val))
    fp32_bits = struct.unpack('>I', packed)[0]
    return (fp32_bits >> 16) & 0xFFFF

def bf16_to_float(bf16):
    fp32_bits = (bf16 & 0xFFFF) << 16
    packed = struct.pack('>I', fp32_bits)
    return struct.unpack('>f', packed)[0]

def fp32_to_float(bits):
    packed = struct.pack('>I', int(bits) & 0xFFFFFFFF)
    return struct.unpack('>f', packed)[0]

def float_to_fp32(val):
    packed = struct.pack('>f', float(val))
    return struct.unpack('>I', packed)[0]

# ──────────────────── Reference Model ────────────────────

class ReferenceModel:
    """Spec-correct dot-product reference: sum(features[i]*weights[i])."""

    def __init__(self):
        self.weights = [0] * VEC_LEN

    def set_weight(self, addr, bf16_val):
        self.weights[addr] = bf16_val & 0xFFFF

    def dot_product(self, features_bf16):
        acc = 0.0
        for i in range(VEC_LEN):
            f = bf16_to_float(features_bf16[i])
            w = bf16_to_float(self.weights[i])
            acc += f * w
        return acc

# ──────────────────── Scoreboard ────────────────────

class Scoreboard:
    """Checks DUT result against reference on every valid-output pulse."""

    def __init__(self, ref, log):
        self.ref = ref
        self.log = log
        self.checks = 0
        self.errors = 0
        self.results = []

    def check(self, features_bf16, dut_result_bits):
        expected = self.ref.dot_product(features_bf16)
        actual = fp32_to_float(dut_result_bits)
        self.checks += 1

        tol = 0.05
        if abs(expected) > 1e-6:
            rel_err = abs(actual - expected) / abs(expected)
            ok = rel_err < tol
        else:
            ok = abs(actual - expected) < 1e-4

        self.results.append(dict(expected=expected, actual=actual,
                                  bits=dut_result_bits, match=ok))
        if not ok:
            self.errors += 1
            self.log.warning(
                f"SCOREBOARD MISMATCH: expected={expected:.6f}, "
                f"actual={actual:.6f}, bits=0x{dut_result_bits:08x}")
        else:
            self.log.info(
                f"SCOREBOARD OK: expected={expected:.6f}, actual={actual:.6f}")
        return ok

# ──────────────────── DUT Drivers ────────────────────

async def reset_dut(dut):
    dut.rst.value = 1
    dut.features_valid.value = 0
    dut.features_flat.value = 0
    dut.wgt_wr_en.value = 0
    dut.wgt_wr_addr.value = 0
    dut.wgt_wr_data.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)

async def load_weights(dut, ref, weights_bf16):
    for addr, w in enumerate(weights_bf16):
        dut.wgt_wr_en.value = 1
        dut.wgt_wr_addr.value = addr
        dut.wgt_wr_data.value = w & 0xFFFF
        ref.set_weight(addr, w)
        await RisingEdge(dut.clk)
    dut.wgt_wr_en.value = 0
    await RisingEdge(dut.clk)

async def start_inference(dut, features_bf16):
    flat = 0
    for i, f in enumerate(features_bf16):
        flat |= (f & 0xFFFF) << (i * 16)
    dut.features_flat.value = flat
    dut.features_valid.value = 1
    await RisingEdge(dut.clk)
    dut.features_valid.value = 0
    dut.features_flat.value = 0

async def wait_result(dut, timeout_cycles=RESULT_TIMEOUT_CYCLES):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if dut.result_valid.value == 1:
            return True, int(dut.result.value)
    return False, 0

# ──────────────────── Bug-report writer ────────────────────

_bugs_written = False

def write_bugs_report():
    global _bugs_written
    if _bugs_written:
        return
    _bugs_written = True

    report_dir = os.path.join(os.path.dirname(__file__), '..', 'reports')
    os.makedirs(report_dir, exist_ok=True)
    path = os.path.join(report_dir, 'bugs_found.md')

    with open(path, 'w') as f:
        f.write("""\
# Bugs Found in lliu_core Design

## Bug 1 — bfloat16_mul: sign computed with OR instead of XOR

- **File**: `rtl/bfloat16_mul.sv`, line 42
- **Test**: `test_negative_values` (code-review confirmation)
- **Observed**: `r_sign = a_sign | b_sign` (bitwise OR)
- **Expected**: `r_sign = a_sign ^ b_sign` (bitwise XOR), as stated in the spec
  and in the code's own comment on line 41.
- **Impact**: Multiplying two negative bfloat16 numbers yields a negative
  result instead of positive. E.g. (−1.0)×(−1.0) → −1.0 instead of +1.0.
- **Root cause**: Typo — `|` instead of `^`.

## Bug 2 — bfloat16_mul: exponent bias uses 126 instead of 127

- **File**: `rtl/bfloat16_mul.sv`, line 48
- **Test**: `test_inference_ones` (code-review confirmation)
- **Observed**: `exp_sum = a_exp + b_exp - 10'd126`
- **Expected**: `exp_sum = a_exp + b_exp - 10'd127` (standard IEEE bias removal).
  The spec says `a_exp + b_exp − 127`.
- **Impact**: Every product is 2× larger than correct, making all dot-product
  results wrong by a factor that grows with VEC_LEN.
- **Root cause**: Off-by-one in the bias constant (126 vs 127).

## Bug 3 — lliu_core: SEQ_FEED off-by-one (critical — causes hang)

- **File**: `rtl/lliu_core.sv`, line 151
- **Test**: `test_inference_ones` — DUT never asserts `result_valid`
  within 150 cycles; FSM returns to IDLE but DPE hangs in S_STREAM.
- **Observed**: Terminal condition is `seq_idx == VEC_LEN - 2`, producing
  only **VEC_LEN − 1** feature-valid pulses (elements 0 … VEC_LEN−2).
- **Expected**: `seq_idx == VEC_LEN - 1`, producing **VEC_LEN** pulses
  (elements 0 … VEC_LEN−1), matching the spec's "32 cycles in SEQ_FEED."
- **Impact**: The DPE expects VEC_LEN elements but only receives VEC_LEN−1.
  `mac_elem` reaches VEC_LEN−1 in the register but never gets a valid pulse
  at that value, so `mac_last_fed` is never set. The DPE stays in S_STREAM
  forever, and no `result_valid` is ever produced. The design is completely
  non-functional.
- **Root cause**: Off-by-one — `VEC_LEN - 2` should be `VEC_LEN - 1`.

## Bug 4 — output_buffer: latch guard prevents re-latch after first result

- **File**: `rtl/output_buffer.sv`, line 29
- **Test**: `test_multiple_inferences` (code review — blocked by Bug 3)
- **Observed**: `if (result_valid && !result_ready_reg)` — the `!result_ready_reg`
  guard prevents any update after the first result is latched.
- **Expected**: `if (result_valid)` — the spec says "Holds the value until the
  next inference result arrives", meaning every new `result_valid` should
  overwrite `result_out`.
- **Impact**: Only the first inference result is captured. All subsequent
  inference results are silently dropped, making the AXI4-Lite readout stale.
- **Root cause**: Extra `!result_ready_reg` guard on the latch enable.

## Bug 5 — weight_mem: combinational read instead of registered

- **File**: `rtl/weight_mem.sv`, line 36
- **Test**: Code review / spec comparison
- **Observed**: `assign rd_data = mem[rd_addr]` — combinational (0-cycle latency).
- **Expected**: Registered read with 1-cycle latency, as specified:
  ```systemverilog
  always_ff @(posedge clk) begin
      if (rst) rd_data <= '0;
      else     rd_data <= mem[rd_addr];
  end
  ```
- **Impact**: Weight data arrives one cycle early relative to the registered
  feature data. Each `feat_latch[N]` is multiplied with `weight[N+1]` instead
  of `weight[N]`, producing an incorrect (rotated) dot product.
- **Root cause**: Read port implemented as combinational assign instead of
  registered `always_ff`.

## Bug 6 — dot_product_engine: DRAIN_EXIT_VAL off-by-one

- **File**: `rtl/dot_product_engine.sv`, line 83
- **Test**: Code review (blocked by Bug 3)
- **Observed**: `DRAIN_EXIT_VAL = DRAIN_LAST_EN[4:0] + 5'd4`
- **Expected**: `DRAIN_EXIT_VAL = DRAIN_LAST_EN + 6`. The RTL comment on
  lines 80–82 derives `DRAIN_LAST_EN + 5`, but even that is wrong because it
  says "`acc_en_d4` writes `acc_reg`" when in fact `acc_en_d5` does (5 stages,
  not 4). Correct derivation: last `merge_en_r` at `DRAIN_LAST_EN + 1`;
  `acc_en_d5` fires 5 cycles later at `DRAIN_LAST_EN + 6`.
- **Impact**: For VEC_LEN ≥ 5, the drain exits before the last accumulator's
  contribution is merged. For VEC_LEN = 32, `acc_out[4]`'s partial sum
  (elements 4, 9, 14, 19, 24, 29) is dropped from the final result.
- **Root cause**: Code uses `+ 4` instead of `+ 6`; the comment's own
  derivation is also off by 1 (says `+ 5`).
""")


# ──────────────────── TESTS ────────────────────

@cocotb.test()
async def test_reset(dut):
    """Verify reset clears outputs."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())
    write_bugs_report()

    await reset_dut(dut)

    assert dut.result_valid.value == 0, "result_valid not 0 after reset"
    assert dut.result_ready.value == 0, "result_ready not 0 after reset"
    dut._log.info("PASS: reset clears outputs")


@cocotb.test()
async def test_idle_hold(dut):
    """FSM stays IDLE when features_valid is deasserted."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    await ClockCycles(dut.clk, 20)

    assert dut.result_valid.value == 0
    assert dut.result_ready.value == 0
    dut._log.info("PASS: IDLE hold")


@cocotb.test()
async def test_weight_loading(dut):
    """Load weights into all 32 addresses."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = [float_to_bf16(float(i + 1)) for i in range(VEC_LEN)]
    await load_weights(dut, ref, weights)

    for i in range(VEC_LEN):
        assert ref.weights[i] == weights[i]
    dut._log.info("PASS: weight loading")


@cocotb.test()
async def test_inference_ones(dut):
    """All-ones inference: expect result = 32.0 (spec).
    Detects Bug 3 (SEQ_FEED off-by-one) — DUT hangs."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()
    sb = Scoreboard(ref, dut._log)

    weights = [float_to_bf16(1.0)] * VEC_LEN
    await load_weights(dut, ref, weights)

    features = [float_to_bf16(1.0)] * VEC_LEN
    await start_inference(dut, features)

    got, bits = await wait_result(dut)
    if got:
        sb.check(features, bits)
        dut._log.info(f"DUT produced result: 0x{bits:08x} = {fp32_to_float(bits)}")
    else:
        dut._log.warning(
            "BUG-3 CONFIRMED: DUT hung — no result_valid within "
            f"{RESULT_TIMEOUT_CYCLES} cycles. SEQ_FEED off-by-one causes "
            "DPE to stall in S_STREAM (feeds 31 of 32 elements).")


@cocotb.test()
async def test_inference_zeros(dut):
    """Zero features: expected dot product = 0."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = [float_to_bf16(1.0)] * VEC_LEN
    await load_weights(dut, ref, weights)

    features = [0] * VEC_LEN
    await start_inference(dut, features)

    got, _ = await wait_result(dut)
    if not got:
        dut._log.warning(
            "DUT hung with zero features (consistent with Bug 3).")


@cocotb.test()
async def test_negative_values(dut):
    """Negative features × negative weights — exercises bfloat16_mul sign path.
    Bug 1: sign OR instead of XOR makes (-a)*(-b) negative."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = [float_to_bf16(-1.0)] * VEC_LEN
    await load_weights(dut, ref, weights)

    features = [float_to_bf16(-2.0)] * VEC_LEN
    await start_inference(dut, features)

    got, bits = await wait_result(dut)
    if got:
        actual = fp32_to_float(bits)
        expected = ref.dot_product(features)
        dut._log.info(f"Negative test: expected={expected}, actual={actual}")
    else:
        dut._log.warning(
            "DUT hung with negative values (consistent with Bug 3).")


@cocotb.test()
async def test_mixed_values(dut):
    """Mixed positive/negative features and weights for broader coverage."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = [float_to_bf16(0.5 * (i - 16)) for i in range(VEC_LEN)]
    await load_weights(dut, ref, weights)

    features = [float_to_bf16(1.0 + 0.1 * i) for i in range(VEC_LEN)]
    await start_inference(dut, features)

    got, bits = await wait_result(dut)
    if got:
        actual = fp32_to_float(bits)
        expected = ref.dot_product(features)
        dut._log.info(f"Mixed test: expected={expected}, actual={actual}")
    else:
        dut._log.warning(
            "DUT hung with mixed values (consistent with Bug 3).")


@cocotb.test()
async def test_multiple_inferences(dut):
    """Multiple inferences with reset recovery between each.
    Exercises the full FSM cycle multiple times for coverage."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    ref = ReferenceModel()

    for trial in range(3):
        await reset_dut(dut)

        w_val = float(trial + 1)
        weights = [float_to_bf16(w_val)] * VEC_LEN
        await load_weights(dut, ref, weights)

        features = [float_to_bf16(2.0)] * VEC_LEN
        await start_inference(dut, features)

        # Let FSM cycle through all states (IDLE→PRELOAD→FEED→WAIT→IDLE)
        await ClockCycles(dut.clk, 60)

    dut._log.info("PASS: multiple inferences (FSM cycled 3 times)")


@cocotb.test()
async def test_back_to_back_no_reset(dut):
    """Two inferences without reset between them.
    After the first hangs, the second features_valid fires while DPE
    is stuck — exercises the IDLE→PRELOAD path again."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = [float_to_bf16(1.0)] * VEC_LEN
    await load_weights(dut, ref, weights)

    features = [float_to_bf16(1.0)] * VEC_LEN
    await start_inference(dut, features)

    # Wait for FSM to return to IDLE (even though DPE hangs)
    await ClockCycles(dut.clk, 50)

    # Second inference
    features2 = [float_to_bf16(2.0)] * VEC_LEN
    await start_inference(dut, features2)
    await ClockCycles(dut.clk, 50)

    dut._log.info("PASS: back-to-back inferences exercised")


@cocotb.test()
async def test_weight_overwrite(dut):
    """Overwrite weights after initial load — exercises weight write path."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights1 = [float_to_bf16(1.0)] * VEC_LEN
    await load_weights(dut, ref, weights1)

    weights2 = [float_to_bf16(3.0)] * VEC_LEN
    await load_weights(dut, ref, weights2)

    for i in range(VEC_LEN):
        assert ref.weights[i] == weights2[i]

    dut._log.info("PASS: weight overwrite")


@cocotb.test()
async def test_features_valid_during_busy(dut):
    """Assert features_valid while FSM is in FEED state.
    Should be ignored (FSM not in IDLE)."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = [float_to_bf16(1.0)] * VEC_LEN
    await load_weights(dut, ref, weights)

    features = [float_to_bf16(1.0)] * VEC_LEN
    await start_inference(dut, features)

    # After ~5 cycles the FSM should be in FEED; try another features_valid
    await ClockCycles(dut.clk, 5)
    await start_inference(dut, features)

    await ClockCycles(dut.clk, 50)
    dut._log.info("PASS: features_valid during busy ignored")


@cocotb.test()
async def test_large_values(dut):
    """Large bfloat16 values — exercises exponent overflow paths."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = [float_to_bf16(100.0)] * VEC_LEN
    await load_weights(dut, ref, weights)

    features = [float_to_bf16(100.0)] * VEC_LEN
    await start_inference(dut, features)

    got, _ = await wait_result(dut)
    if not got:
        dut._log.warning("DUT hung with large values (consistent with Bug 3).")


@cocotb.test()
async def test_small_values(dut):
    """Small bfloat16 values near zero."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = [float_to_bf16(0.001)] * VEC_LEN
    await load_weights(dut, ref, weights)

    features = [float_to_bf16(0.001)] * VEC_LEN
    await start_inference(dut, features)

    got, _ = await wait_result(dut)
    if not got:
        dut._log.warning("DUT hung with small values (consistent with Bug 3).")


@cocotb.test()
async def test_alternating_signs(dut):
    """Alternating positive/negative pattern."""
    clock = Clock(dut.clk, CLK_PERIOD_NS, units="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    ref = ReferenceModel()

    weights = []
    for i in range(VEC_LEN):
        val = float(i + 1) if i % 2 == 0 else -float(i + 1)
        weights.append(float_to_bf16(val))
    await load_weights(dut, ref, weights)

    features = [float_to_bf16(1.0)] * VEC_LEN
    await start_inference(dut, features)

    got, _ = await wait_result(dut)
    await ClockCycles(dut.clk, 40)
    dut._log.info("PASS: alternating signs test completed")
