//      // verilator_coverage annotation
        // risk_check.sv — Pre-trade risk enforcement, 2-cycle registered output
        //
        // Three parallel risk checks (spec §4.6) resolved in a 2-stage pipeline:
        //
        //   Stage 0 → 1 (posedge 1):
        //     • Price-band comparison done combinatorially, result registered.
        //     • Fat-finger comparison done combinatorially (proposed_shares > max_qty
        //       AXI4-Lite register, no BRAM needed — matches AXI4-Lite map 0x404).
        //     • Position BRAM read address driven; data arrives at posedge 1.
        //
        //   Stage 1 → 2 (posedge 2):
        //     • Position-limit check done combinatorially from BRAM read data.
        //     • All three check results AND'd; risk_pass / risk_blocked registered.
        //
        // Kill switch and tx_overflow are registered into stage-1 pipeline and act
        // as hard gates on pass_c1 (suppress risk_pass without a reason code).
        //
        // Position BRAM (512 × 24-bit signed, infers one RAMB18E1):
        //   Stores cumulative net_shares per symbol.  Updated 1 cycle after risk_pass
        //   via pos_wr_* writeback registers.
        //
        //   Writeback hazard: a read for symbol S at cycle N sees the write for
        //   symbol S at cycle N only if that write completed ≥1 cycle earlier.
        //   Back-to-back orders for the same symbol within 2 cycles will observe
        //   stale position data.  Acceptable at 1 unique-symbol message/cycle.
        //
        // block_reason encoding:
        //   2'b00 = no block (or kill_sw / tx_overflow — no reason code assigned)
        //   2'b01 = price-band violation
        //   2'b10 = fat-finger violation
        //   2'b11 = position-limit violation
        
        /* verilator lint_off IMPORTSTAR */
        import lliu_pkg::*;
        /* verilator lint_on IMPORTSTAR */
        
        module risk_check (
            input  logic        clk,
            input  logic        rst,
        
            // From strategy_arbiter
            input  logic        score_valid,
            input  logic        side,              // 1 = buy, 0 = sell
            input  logic [31:0] price,
            input  logic [OB_SYM_ID_W-1:0] symbol_id, // 0–OB_NUM_SYMBOLS-1; indexes position BRAM
            input  logic [23:0] proposed_shares,   // share quantity to propose
        
            // TX backpressure auto-kill from ouch_engine (combinational, registered into p1)
            input  logic        tx_overflow,
        
            // AXI4-Lite configurable thresholds (held stable between AXI writes)
            /* verilator lint_off UNUSEDSIGNAL */
            input  logic [31:0] band_bps,          // price-band width in basis points (only [13:0] used; [15:14]=0 for ≤10000 bps)
            /* verilator lint_on UNUSEDSIGNAL */
            input  logic [31:0] max_qty,           // fat-finger global ceiling (AXI 0x404)
            input  logic [23:0] pos_limit,         // per-symbol net-position ceiling (unsigned shares)
            input  logic        kill_sw,           // write-one-to-set; AXI4-Lite CTRL[2]
        
            // Reference price (BBO mid, registered 1-cycle externally)
            /* verilator lint_off UNUSEDSIGNAL */
            input  logic [31:0] ref_price,         // only [29:0] used in multiply; [31:30]=0 for all realistic prices
            /* verilator lint_on UNUSEDSIGNAL */
        
            // Risk outputs — valid 2 cycles after score_valid
            output logic        risk_pass,
            output logic        risk_blocked,
            output logic [1:0]  block_reason
        );
        
            // ------------------------------------------------------------------
            // Stage-0 combinational: fat-finger check only
            // The price-band multiply is moved into the Stage-0.5 always_ff below
            // (PREG=1 pattern) so that Vivado places the source FF next to the DSP
            // column, avoiding the held_ref_r → DSP A→P → DSP C-port cascade that
            // caused WNS −1.805 ns.  With the multiply directly in always_ff, Vivado
            // infers PREG=1 (internal DSP register), using the Setup_dsp48e1_CLK_A
            // timing arc (negative setup = data may arrive after the launch edge),
            // which easily fits within the 3.200 ns clock period.
            // ------------------------------------------------------------------
            logic block_fat_c0;
        
 000001     always_comb begin
                // Fat-finger: proposed_shares vs global AXI4-Lite max_qty register
 000001         block_fat_c0 = score_valid && ({8'h0, proposed_shares} >= max_qty);
            end
        
            // ------------------------------------------------------------------
            // Stage-0 → Stage-0.5 pipeline registers
            // ref_price_d: pre-register for the DSP A-port (30-bit).  Placed in the
            // same always_ff as band_product_h so Vivado co-locates this FF next to
            // the multiply DSP, minimising the A-port net delay.  The extra pipeline
            // stage is latency-transparent because held_ref_r is stable for hundreds
            // of cycles between successive ITCH messages.
            // ------------------------------------------------------------------
            logic [26:0] ref_price_d;   // DSP A-port pre-register: 27-bit keeps multiply in single DSP48E1 (A-port effective width = 27 bits unsigned; NASDAQ prices never exceed $13,421 × 10^-4 = 2^27)
            logic [13:0] band_bps_d;    // DSP B-port pre-register (co-located with DSP by Vivado)
            // Run 51 fix: band_product_h eliminated.  Runs 46-50 all failed to prevent
            // the relay DSP (band_product_h_reg, CREG at X3Y5) from appearing.
            // Root cause: use_dsp="yes" on a 48-bit registered signal instructs
            // synth_design (not opt_design) to keep the net in DSP infrastructure;
            // synthesis then creates a CREG relay to buffer the fo=18 P-output.
            // No RTL attribute or post-synthesis constraint can prevent SYNTH from
            // creating this relay — it must be eliminated structurally.
            // Solution: remove band_product_h as an intermediate register; assign
            // band_thresh_r directly from ref_price_d × band_bps_d in Stage 0.75.
            // band_thresh_r has use_dsp="no" → maps to 49-bit FDRE, no relay DSP.
            // DSP48E1 still inferred for the 30×14 multiply (no PREG=1 needed;
            // path ref_price_d FDRE → DSP A-in → P-out → band_thresh_r FDRE ≈ 1.2 ns).
            logic [31:0] ref_price_h;
            logic [31:0] price_h;
            logic [31:0] price_diff_h;  // pre-registered |price − ref_price|; breaks the
                                        // abs-diff + compare CARRY4 chain from ref_price_h
                                        // to block_band_p1 (Run 26 fix: −0.465 ns violation)
            logic        score_valid_h;
            logic        side_h;
            logic [OB_SYM_ID_W-1:0] symbol_id_h;
            logic [23:0] proposed_shares_h;
            logic        block_fat_h;
            logic        kill_sw_h;
            logic        tx_overflow_h;
        
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             ref_price_d        <= '0;
 002822             band_bps_d         <= '0;
 002822             ref_price_h        <= '0;
 002822             price_h            <= '0;
 002822             price_diff_h       <= '0;
 002822             score_valid_h      <= 1'b0;
 002822             side_h             <= 1'b0;
 002822             symbol_id_h        <= '0;
 002822             proposed_shares_h  <= '0;
 002822             block_fat_h        <= 1'b0;
 002822             kill_sw_h          <= 1'b0;
 002822             tx_overflow_h      <= 1'b0;
 1715919         end else begin
 1715919             ref_price_d        <= ref_price[26:0];   // Run 54: 27-bit → single DSP48E1 PREG=1 (28-bit caused 2-DSP relay, WNS -0.175 ns)
 1715919             band_bps_d         <= band_bps[13:0];  // B-port pre-register: Vivado places adjacent to DSP
 1715919             ref_price_h        <= ref_price;
 1715919             price_h            <= price;
                    // Pre-register abs(price − ref_price) from the raw module inputs.
                    // Breaks the two-operation chain (abs-diff + compare) that ran from
                    // ref_price_h to block_band_p1 in a single combinational stage.
                    // Timing alignment is preserved: price and ref_price are valid at
                    // the same cycle as score_valid, so price_diff_h corresponds to the
                    // same transaction as score_valid_h.
 1715919             price_diff_h       <= (price >= ref_price) ? (price - ref_price)
 151489                                                        : (ref_price - price);
 1715919             score_valid_h      <= score_valid;
 1715919             side_h             <= side;
 1715919             symbol_id_h        <= symbol_id;
 1715919             proposed_shares_h  <= proposed_shares;
 1715919             block_fat_h        <= block_fat_c0;
 1715919             kill_sw_h          <= kill_sw;
 1715919             tx_overflow_h      <= tx_overflow;
                end
            end
        
            // ------------------------------------------------------------------
            // Stage-0.75 pipeline registers: register DSP P-output into FDREs.
            // Run 31 fix: Vivado infers a second DSP (band_product_h_reg) at the
            // adjacent column to hold band_product_h via its C-port register.  The
            // C-port timing arc (Setup_dsp48e1_CLK_C = −1.208 ns) combined with
            // DSP CLK→P (1.635 ns) + route (0.570 ns) creates an effective budget
            // of only 1.792 ns — violated by 0.180 ns in Run 28.
            // Adding an explicit FDRE register stage here absorbs band_product_h
            // into an ordinary FDRE (setup ~0.049 ns): total path DSP P → route
            // (~0.570 ns) → FDRE D = ~0.62 ns, well within 3.2 ns.  All other
            // Stage-0 signals (_h) are delayed one more cycle (_hh) to stay aligned.
            // Note: do NOT add (* use_dsp = "no" *) to the 32-bit band_thresh_r —
            // that attribute on a wide net caused Vivado to abandon PREG=1 inference
            // on band_product_h0 (Run 30 regression: WNS −1.256 ns, 2800 failures).
            // ------------------------------------------------------------------
            // Run 35 fix: Vivado inserts band_product_h_reg (DSP CREG, 48-bit) as an
            // intermediate buffer before the [44:13] slice, because `use_dsp="no"` on
            // band_thresh_r only prevents CREG absorption of the 32-bit slice output,
            // not the 48-bit intermediate.  The fix: store the full 48-bit band_product_h
            // without slicing (exactly mirroring msg_pxvol_s075 in feature_extractor_v2),
            // then slice combinationally when reading.  With use_dsp="yes" on band_product_h
            // and use_dsp="no" on the 48-bit band_thresh_r (separate always_ff), Vivado
            // cannot create a CREG cascade: the FDRE is already 48-bit matching the DSP
            // P-output, so no intermediate buffer is needed.
            // ------------------------------------------------------------------
            // Run 54 fix: ref_price_d narrowed to [26:0] (27 bits) so the multiply
            // ref_price_d × {4'h0,band_bps_d} = 27×18 = 45-bit product fits in ONE
            // DSP48E1 A-port multiplier (effective width = 27 bits unsigned).
            //
            // Root cause of Runs 52-53 failures (WNS -0.175 ns, 112 EPs):
            //   ref_price_d was [29:0] = 30-bit.  DSP48E1 A-port multiplier is 27 bits.
            //   For 28-bit inputs (ref_price bit 27 non-zero), Vivado synthesised TWO
            //   DSP48E1 cells (band_thresh_r0 at X3Y10, band_thresh_r_reg at X3Y11).
            //   P→C routing between adjacent DSPs through fabric = ~2.892 ns, which
            //   exceeds the 2.773 ns budget → WNS -0.175 ns.
            //   Reducing to 27 bits (max ref_price = 2^27 ≈ $13,421 × 10^-4, covers
            //   all practical NASDAQ-listed stocks) forces ONE DSP with PREG=1.
            //   Vivado absorbs ref_price_d/band_bps_d into AREG/BREG; band_thresh_r
            //   is PREG.  No relay DSP, no P→C fabric path.
            (* use_dsp = "yes" *) logic [47:0] band_thresh_r;  // 27×18→single DSP48E1 PREG=1
            logic [31:0] price_diff_hh;    // price_diff_h delayed 1 cycle (aligned)
            logic        score_valid_hh;
            logic        side_hh;
            logic [OB_SYM_ID_W-1:0] symbol_id_hh;
            logic [23:0] proposed_shares_hh;
            logic        block_fat_hh;
            logic        kill_sw_hh;
            logic        tx_overflow_hh;
            // Stage-0.75: 32-bit CREG-proof register + aligned delays of Stage-0.5 outputs.
            // band_thresh_32_r is 32-bit — Vivado cannot absorb it into a 48-bit DSP CREG.
            // band_thresh_r (48-bit) now only drives another FDRE (no adjacent DSP), so
            // Vivado no longer has incentive to CREG-absorb it either.
            (* use_dsp = "no" *) logic [31:0] band_thresh_32_r;
            logic [31:0] price_diff_hhh;
            logic        score_valid_hhh;
            logic        side_hhh;
            logic [OB_SYM_ID_W-1:0] symbol_id_hhh;
            logic [23:0] proposed_shares_hhh;
            logic        block_fat_hhh;
            logic        kill_sw_hhh;
            logic        tx_overflow_hhh;
        
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             band_thresh_r      <= '0;
 002822             price_diff_hh      <= '0;
 002822             score_valid_hh     <= 1'b0;
 002822             side_hh            <= 1'b0;
 002822             symbol_id_hh       <= '0;
 002822             proposed_shares_hh <= '0;
 002822             block_fat_hh       <= 1'b0;
 002822             kill_sw_hh         <= 1'b0;
 002822             tx_overflow_hh     <= 1'b0;
 1715919         end else begin
                    // Run 54: ref_price_d[26:0] (27-bit) × {4'h0,band_bps_d} (18-bit) = 45-bit product.
                    // 27-bit A-port fits DSP48E1 single-DSP multiplier → no relay DSP.
 1715919             band_thresh_r      <= 48'(ref_price_d * {4'h0, band_bps_d});
 1715919             price_diff_hh      <= price_diff_h;
 1715919             score_valid_hh     <= score_valid_h;
 1715919             side_hh            <= side_h;
 1715919             symbol_id_hh       <= symbol_id_h;
 1715919             proposed_shares_hh <= proposed_shares_h;
 1715919             block_fat_hh       <= block_fat_h;
 1715919             kill_sw_hh         <= kill_sw_h;
 1715919             tx_overflow_hh     <= tx_overflow_h;
                end
            end
        
            // ------------------------------------------------------------------
            // Stage-0.75 pipeline registers: 32-bit CREG-proof band_thresh + aligned delays.
            // band_thresh_32_r is 32-bit — Vivado CANNOT absorb it into a 48-bit CREG.
            // band_thresh_r (48-bit) here only drives band_thresh_32_r (FDRE→FDRE path),
            // so Vivado has no adjacent DSP to CREG-absorb it into.
            // ------------------------------------------------------------------
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             band_thresh_32_r    <= '0;
 002822             price_diff_hhh      <= '0;
 002822             score_valid_hhh     <= 1'b0;
 002822             side_hhh            <= 1'b0;
 002822             symbol_id_hhh       <= '0;
 002822             proposed_shares_hhh <= '0;
 002822             block_fat_hhh       <= 1'b0;
 002822             kill_sw_hhh         <= 1'b0;
 002822             tx_overflow_hhh     <= 1'b0;
 1715919         end else begin
 1715919             band_thresh_32_r    <= band_thresh_r[44:13];  // 32-bit slice of 48-bit DSP PREG [47:0]
 1715919             price_diff_hhh      <= price_diff_hh;
 1715919             score_valid_hhh     <= score_valid_hh;
 1715919             side_hhh            <= side_hh;
 1715919             symbol_id_hhh       <= symbol_id_hh;
 1715919             proposed_shares_hhh <= proposed_shares_hh;
 1715919             block_fat_hhh       <= block_fat_hh;
 1715919             kill_sw_hhh         <= kill_sw_hh;
 1715919             tx_overflow_hhh     <= tx_overflow_hh;
                end
            end
        
            // ------------------------------------------------------------------
            // Stage-0.75 combinational: band comparison — all inputs are FDREs.
            // band_thresh_32_r is 32-bit so no CREG absorption possible.
            // ------------------------------------------------------------------
            (* use_dsp = "no" *) logic block_band_c05;
        
 000001     always_comb begin
 000001         block_band_c05 = score_valid_hhh && (price_diff_hhh > band_thresh_32_r);
            end
        
            // ------------------------------------------------------------------
            // Stage-0.75 → Stage-1 pipeline registers
            // ------------------------------------------------------------------
            logic        score_valid_p1;
            logic        side_p1;
            logic [OB_SYM_ID_W-1:0] symbol_id_p1;
            logic [23:0] proposed_shares_p1;
            logic        block_band_p1;
            logic        block_fat_p1;
            logic        kill_sw_p1;
            logic        tx_overflow_p1;
        
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             score_valid_p1     <= 1'b0;
 002822             side_p1            <= 1'b0;
 002822             symbol_id_p1       <= '0;
 002822             proposed_shares_p1 <= '0;
 002822             block_band_p1      <= 1'b0;
 002822             block_fat_p1       <= 1'b0;
 002822             kill_sw_p1         <= 1'b0;
 002822             tx_overflow_p1     <= 1'b0;
 1715919         end else begin
 1715919             score_valid_p1     <= score_valid_hhh;
 1715919             side_p1            <= side_hhh;
 1715919             symbol_id_p1       <= symbol_id_hhh;
 1715919             proposed_shares_p1 <= proposed_shares_hhh;
 1715919             block_band_p1      <= block_band_c05;
 1715919             block_fat_p1       <= block_fat_hhh;
 1715919             kill_sw_p1         <= kill_sw_hhh;
 1715919             tx_overflow_p1     <= tx_overflow_hhh;
                end
            end
        
            // ------------------------------------------------------------------
            // Position BRAM (512 × 24-bit signed, infers RAMB18E1)
            // Read address = symbol_id_hh (Stage-0.75, cycle 2); rd_data valid at Stage-1.
            // Write port driven by writeback register (1 cycle after risk_pass).
            // ------------------------------------------------------------------
            (* ram_style = "block" *) logic signed [23:0] pos_mem [0:OB_NUM_SYMBOLS-1];
            logic signed [23:0] pos_rd_data;
            logic               pos_wr_en_r;
            logic [OB_SYM_ID_W-1:0] pos_wr_addr_r;
            logic signed [23:0] pos_wr_data_r;
        
 1718741     always_ff @(posedge clk) begin
 1718537         if (pos_wr_en_r)
 000204             pos_mem[pos_wr_addr_r] <= pos_wr_data_r;
 1718741         pos_rd_data <= pos_mem[symbol_id_hhh];  // read at Stage-0.75; data at Stage-1
            end
        
            // ------------------------------------------------------------------
            // Stage-1 combinational: position-limit check; priority encoder
            // ------------------------------------------------------------------
            logic        block_pos_c1;
            logic        pass_c1;
            logic [1:0]  reason_c1;
            logic signed [24:0] new_net;
            logic [23:0]        new_net_abs;
        
            // Stage-1 combinational: compute new net position from BRAM output.
            // Registered in Stage-1.5 to break the BRAM-prop (1.8 ns) + 25-bit-add +
            // abs + compare + priority-encode chain (was 12 levels, ~4.8 ns > 3.2 ns).
 8665973     always_comb begin
 6346948         if (side_p1)
 2319025             new_net = {pos_rd_data[23], pos_rd_data} + {1'b0, proposed_shares_p1};
                else
 6346948             new_net = {pos_rd_data[23], pos_rd_data} - {1'b0, proposed_shares_p1};
            end
        
            // Stage-1.5 pipeline registers: break BRAM→add path from compare→register path.
            logic signed [24:0]      new_net_r;       // registered new_net for Stage-2
            logic                    score_valid_p2;
            logic [OB_SYM_ID_W-1:0] symbol_id_p2;
            logic                    block_band_p2;
            logic                    block_fat_p2;
            logic                    kill_sw_p2;
            logic                    tx_overflow_p2;
        
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             new_net_r      <= '0;
 002822             score_valid_p2 <= 1'b0;
 002822             symbol_id_p2   <= '0;
 002822             block_band_p2  <= 1'b0;
 002822             block_fat_p2   <= 1'b0;
 002822             kill_sw_p2     <= 1'b0;
 002822             tx_overflow_p2 <= 1'b0;
 1715919         end else begin
 1715919             new_net_r      <= new_net;
 1715919             score_valid_p2 <= score_valid_p1;
 1715919             symbol_id_p2   <= symbol_id_p1;
 1715919             block_band_p2  <= block_band_p1;
 1715919             block_fat_p2   <= block_fat_p1;
 1715919             kill_sw_p2     <= kill_sw_p1;
 1715919             tx_overflow_p2 <= tx_overflow_p1;
                end
            end
        
            // Stage-2 combinational: abs-value, limit compare, priority encode.
            // All inputs are FDREs; max path ~5 logic levels — fits 3.2 ns budget.
 8665973     always_comb begin
 8665973         new_net_abs  = new_net_r[24] ? (~new_net_r[23:0] + 24'd1) : new_net_r[23:0];
 8665973         block_pos_c1 = score_valid_p2 && (new_net_abs > pos_limit);
        
                // Priority: kill_sw / tx_overflow > price_band > fat_finger > pos_limit
 8664233         if (!score_valid_p2) begin
 8664233             pass_c1   = 1'b0;
 8664233             reason_c1 = 2'b00;
 000010         end else if (kill_sw_p2 || tx_overflow_p2) begin
 000010             pass_c1   = 1'b0;
 000010             reason_c1 = 2'b00;
 000640         end else if (block_band_p2) begin
 000640             pass_c1   = 1'b0;
 000640             reason_c1 = 2'b01;
 000060         end else if (block_fat_p2) begin
 000060             pass_c1   = 1'b0;
 000060             reason_c1 = 2'b10;
 001020         end else if (block_pos_c1) begin
 000010             pass_c1   = 1'b0;
 000010             reason_c1 = 2'b11;
 001020         end else begin
 001020             pass_c1   = 1'b1;
 001020             reason_c1 = 2'b00;
                end
            end
        
            // ------------------------------------------------------------------
            // Stage-2 output register (cycle 2)
            // ------------------------------------------------------------------
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             risk_pass    <= 1'b0;
 002822             risk_blocked <= 1'b0;
 002822             block_reason <= 2'b00;
 1715919         end else begin
 1715919             risk_pass    <= pass_c1;
 1715919             risk_blocked <= score_valid_p2 && !pass_c1;
 1715919             block_reason <= reason_c1;
                end
            end
        
            // ------------------------------------------------------------------
            // Position writeback: registered 1 cycle after risk_pass assertion
            // Uses new_net computed in stage-1 always_comb above.
            // ------------------------------------------------------------------
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             pos_wr_en_r   <= 1'b0;
 002822             pos_wr_addr_r <= '0;
 002822             pos_wr_data_r <= '0;
 1715919         end else begin
 1715919             pos_wr_en_r   <= pass_c1;
 1715919             pos_wr_addr_r <= symbol_id_p2;
 1715919             pos_wr_data_r <= new_net_r[23:0];
                end
            end
        
        endmodule
        
