# RTL Bugs Found in itch_field_extract.sv

## Bug 1: order_ref extracts wrong byte (byte 10 instead of byte 11)

**Test:** ADD_ORDER_BUY, ADD_ORDER_SELL (detected during code review, confirmed by scoreboard alignment)

**Symptom:** The MSB of `order_ref` output contains the last byte of the
timestamp field (byte 10) instead of the first byte of the
order_reference_number field (byte 11). Byte 11 is skipped entirely.

**Location:** `rtl/itch_field_extract.sv`, line 54

```systemverilog
assign order_ref_comb = {
    msg_data[(B-1-10)*8 +: 8],   // ← BUG: should be (B-1-11)
    msg_data[(B-1-12)*8 +: 8],   // byte 12 (skips byte 11)
    ...
```

**Root cause:** Off-by-one index error. The first element of the
concatenation uses byte offset 10 instead of 11. The correct extraction for
bytes 11–18 (big-endian order_reference_number) should start at index 11.

**Fix:** Change `(B-1-10)` to `(B-1-11)` on line 54.

---

## Bug 2: fields_valid is not cleared on synchronous reset

**Test:** RESET_BEHAVIOUR

**Symptom:** After asserting synchronous reset (`rst=1`) while
`fields_valid` is high, all other registered outputs are correctly cleared
to zero, but `fields_valid` retains its previous value (stays 1).

**Location:** `rtl/itch_field_extract.sv`, lines 92–97

```systemverilog
always_ff @(posedge clk) begin
    if (rst) begin
        message_type <= 8'h00;
        order_ref    <= 64'd0;
        side         <= 1'b0;
        price        <= 32'd0;
        stock        <= 64'd0;
        // fields_valid is MISSING here
    end else begin
        ...
        fields_valid <= fields_valid_comb;
    end
end
```

**Root cause:** `fields_valid` was omitted from the reset block. Every other
registered output is explicitly driven to zero when `rst` is asserted, but
`fields_valid` is only assigned in the `else` branch. During reset it holds
its last value.

**Fix:** Add `fields_valid <= 1'b0;` inside the `if (rst)` block.
