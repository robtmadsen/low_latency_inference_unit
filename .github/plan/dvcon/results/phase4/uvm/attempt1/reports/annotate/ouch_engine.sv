//      // verilator_coverage annotation
        // ouch_engine.sv — OUCH 5.0 Enter Order packet assembler with BRAM template buffer
        //
        // Template buffer: 4 × 128-entry × 64-bit block RAMs (RAMB18E1 × 4), one per
        // static beat slot (beats 2-5).  Per-symbol values (stock name, side indicator,
        // firm, display, TIF) are stored in the BRAMs and initialised via AXI4-Lite.
        // Hot-patched fields per order: order_token (auto-increment), shares, price.
        //
        // Template BRAM layout (per 64-bit entry, indexed by symbol_id):
        //   tmpl_b2[sym]: bits[31:0] = stock[63:32] (stock name bytes 0-3)
        //                 bits[63:32] = placeholder (overwritten by shares at send time)
        //   tmpl_b3[sym]: bits[63:32] = stock[31:0] (stock name bytes 4-7)
        //                 bits[31:0]  = placeholder (overwritten by price at send time)
        //   tmpl_b4[sym]: {TIF[31:0], firm[63:32]}   — time-in-force + firm name bytes 0-3
        //   tmpl_b5[sym]: {firm[31:0], display[7:0], reserved[23:0]}
        //
        // AXI4-Lite write address decode:
        //   tmpl_wr_addr[8:2] = symbol_id (0-127)
        //   tmpl_wr_addr[1:0] = beat_offset: 0=beat2, 1=beat3, 2=beat4, 3=beat5
        //
        // FSM: IDLE → FETCH → LOAD → SEND → IDLE
        //   IDLE  : wait for risk_pass; latch per-order inputs; → FETCH
        //   FETCH : 1-cycle hold; BRAM read (issued from latch_sym_id) completes; → LOAD
        //   LOAD  : assemble all 6 beats; output beat 0 on AXI4-S; → SEND
        //   SEND  : stream beats 1-5 with backpressure handling
        //
        // tx_overflow:
        //   Asserts after 64 consecutive stalled cycles (m_axis_tready=0 during SEND).
        //   Self-clears after 256 consecutive free cycles (m_axis_tready=1).
        
        /* verilator lint_off IMPORTSTAR */
        import lliu_pkg::*;
        /* verilator lint_on IMPORTSTAR */
        
        module ouch_engine (
            input  logic        clk,
            input  logic        rst,
        
            // From risk_check (carries validated order)
            input  logic        risk_pass,
            input  logic        side,              // 1 = buy, 0 = sell
            input  logic [31:0] price,
            input  logic [6:0]  symbol_id,         // 0-127; indexes template BRAMs
            input  logic [23:0] proposed_shares,   // share quantity (from risk_check)
            /* verilator lint_off UNUSED */
            input  logic [63:0] timestamp,         // PTP tap — reserved, not in OUCH packet
            /* verilator lint_on UNUSED */
        
            // Template BRAM write port (AXI4-Lite accessible)
            input  logic [8:0]  tmpl_wr_addr,      // [8:2]=symbol_id, [1:0]=beat_offset
            input  logic [63:0] tmpl_wr_data,
            input  logic        tmpl_wr_en,
        
            // AXI4-Stream master (to 10GbE TX MAC)
            output logic [63:0] m_axis_tdata,
            output logic [7:0]  m_axis_tkeep,
            output logic        m_axis_tvalid,
            output logic        m_axis_tlast,
            input  logic        m_axis_tready,
        
            // Back-pressure watchdog output (→ risk_check auto-kill)
            output logic        tx_overflow
        );
        
            // ------------------------------------------------------------------
            // Packet constants
            // ------------------------------------------------------------------
            localparam logic [7:0] MSG_TYPE  = 8'h4F;           // 'O'
            localparam logic [7:0] SIDE_BUY  = OUCH_SIDE_BUY;
            localparam logic [7:0] SIDE_SELL = OUCH_SIDE_SELL;
        
            // ------------------------------------------------------------------
            // Template BRAMs (4 × 128-entry × 64-bit, infer RAMB18E1 each)
            // ------------------------------------------------------------------
            (* ram_style = "block" *) logic [31:0] tmpl_b2 [0:127]; // stock name bytes 0-3
            (* ram_style = "block" *) logic [31:0] tmpl_b3 [0:127]; // stock name bytes 4-7
            (* ram_style = "block" *) logic [63:0] tmpl_b4 [0:127]; // {TIF, firm_high}
            (* ram_style = "block" *) logic [63:0] tmpl_b5 [0:127]; // {firm_low, display, rsvd}
        
            logic [31:0] tmpl_rd_b2, tmpl_rd_b3;
            logic [63:0] tmpl_rd_b4, tmpl_rd_b5;
            logic [6:0]  latch_sym_id;   // registered from symbol_id at S_IDLE
        
            // Synchronous write + read (simple dual-port pattern, infers block RAM)
 031960     always_ff @(posedge clk) begin
~031956         if (tmpl_wr_en) begin
%000004             case (tmpl_wr_addr[1:0])
%000001                 2'b00: tmpl_b2[tmpl_wr_addr[8:2]] <= tmpl_wr_data[31:0];
%000001                 2'b01: tmpl_b3[tmpl_wr_addr[8:2]] <= tmpl_wr_data[31:0];
%000001                 2'b10: tmpl_b4[tmpl_wr_addr[8:2]] <= tmpl_wr_data;
%000001                 2'b11: tmpl_b5[tmpl_wr_addr[8:2]] <= tmpl_wr_data;
                    endcase
                end
                // Read address driven by latch_sym_id (valid from S_FETCH onwards)
 031960         tmpl_rd_b2 <= tmpl_b2[latch_sym_id];
 031960         tmpl_rd_b3 <= tmpl_b3[latch_sym_id];
 031960         tmpl_rd_b4 <= tmpl_b4[latch_sym_id];
 031960         tmpl_rd_b5 <= tmpl_b5[latch_sym_id];
            end
        
            // ------------------------------------------------------------------
            // FSM
            // ------------------------------------------------------------------
            typedef enum logic [1:0] {
                S_IDLE  = 2'b00,
                S_FETCH = 2'b01,
                S_LOAD  = 2'b10,
                S_SEND  = 2'b11
            } state_t;
        
            state_t     state;
            logic [2:0] beat_cnt;   // 0..5
        
            // ------------------------------------------------------------------
            // Order token (64-bit auto-increment counter)
            // ------------------------------------------------------------------
            logic [63:0] order_token;
        
            // ------------------------------------------------------------------
            // Per-order latched inputs
            // ------------------------------------------------------------------
            logic        latch_side;
            logic [31:0] latch_price;
            logic [23:0] latch_shares;
        
            // ------------------------------------------------------------------
            // Beat buffer (beats 1-5; beat 0 driven directly from S_LOAD)
            // ------------------------------------------------------------------
            logic [63:0] beat_buf [1:5];
        
            // ------------------------------------------------------------------
            // Back-pressure watchdog
            // ------------------------------------------------------------------
            logic [5:0] bp_cnt;     // 64-cycle backpressure threshold
            logic [7:0] clr_cnt;    // 256-cycle self-clear counter
            logic       tx_ovf_r;
        
 031960     always_ff @(posedge clk) begin
 031928         if (rst) begin
 000032             bp_cnt    <= 6'h0;
 000032             clr_cnt   <= 8'h0;
 000032             tx_ovf_r  <= 1'b0;
 031928         end else begin
~031928             if (state == S_SEND && !m_axis_tready) begin
%000000                 clr_cnt <= 8'h0;
%000000                 if (bp_cnt >= 6'h1) begin
%000000                     tx_ovf_r <= 1'b1;
%000000                 end else begin
%000000                     bp_cnt <= bp_cnt + 6'h1;
                        end
 031928             end else begin
 031928                 bp_cnt <= 6'h0;
~031928                 if (tx_ovf_r) begin
%000000                     if (&clr_cnt) begin     // 255 consecutive free cycles
%000000                         tx_ovf_r <= 1'b0;
%000000                         clr_cnt  <= 8'h0;
%000000                     end else begin
%000000                         clr_cnt <= clr_cnt + 8'h1;
                            end
                        end
                    end
                end
            end
        
            assign tx_overflow = tx_ovf_r;
        
            // ------------------------------------------------------------------
            // Main FSM
            // ------------------------------------------------------------------
 031960     always_ff @(posedge clk) begin
 031928         if (rst) begin
 000032             state         <= S_IDLE;
 000032             beat_cnt      <= 3'h0;
 000032             order_token   <= 64'h0;
 000032             latch_sym_id  <= 7'h0;
 000032             latch_side    <= 1'b0;
 000032             latch_price   <= 32'h0;
 000032             latch_shares  <= 24'h0;
 000032             m_axis_tvalid <= 1'b0;
 000032             m_axis_tlast  <= 1'b0;
 000032             m_axis_tkeep  <= 8'hFF;
 000032             m_axis_tdata  <= 64'h0;
 000160             for (int i = 1; i <= 5; i++) beat_buf[i] <= 64'h0;
 031928         end else begin
 031928             case (state)
        
                        // --------------------------------------------------------
 031824                 S_IDLE: begin
 031824                     m_axis_tvalid <= 1'b0;
 031824                     m_axis_tlast  <= 1'b0;
 031811                     if (risk_pass) begin
 000013                         latch_sym_id  <= symbol_id;
 000013                         latch_side    <= side;
 000013                         latch_price   <= price;
 000013                         latch_shares  <= proposed_shares;
                                // latch_sym_id takes effect next cycle (S_FETCH),
                                // so the BRAM read in S_FETCH uses the correct address.
 000013                         state <= S_FETCH;
                            end
                        end
        
                        // --------------------------------------------------------
 000013                 S_FETCH: begin
                            // latch_sym_id is now valid → BRAM initiates read this posedge;
                            // tmpl_rd_b* will hold the correct data by S_LOAD.
 000013                     state <= S_LOAD;
                        end
        
                        // --------------------------------------------------------
 000013                 S_LOAD: begin
                            // BRAM template data (tmpl_rd_b2/b3/b4/b5) is now valid.
                            // Assemble all 6 beats; output beat 0 immediately.
        
                            // Beat 0: message_type + order_token high 7 bytes
 000013                     m_axis_tdata  <= {MSG_TYPE,
 000013                                       order_token[63:56], order_token[55:48],
 000013                                       order_token[47:40], order_token[39:32],
 000013                                       order_token[31:24], order_token[23:16],
 000013                                       order_token[15:8]};
 000013                     m_axis_tvalid <= 1'b1;
 000013                     m_axis_tlast  <= 1'b0;
 000013                     m_axis_tkeep  <= 8'hFF;
        
                            // Beat 1: order_token LSB + 6 ASCII-'0' padding + buy/sell indicator
 000013                     beat_buf[1] <= {order_token[7:0],
 000013                                     8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30,
 000013                                     latch_side ? SIDE_BUY : SIDE_SELL};
        
                            // Beat 2 hot-patch: shares[31:0] (big-endian) into [63:32];
                            //   stock name bytes 0-3 from 32-bit template
 000013                     beat_buf[2] <= {{8'h0, latch_price[23:0]}, tmpl_rd_b2};
        
                            // Beat 3 hot-patch: stock name bytes 4-7 from 32-bit template;
                            //   price[31:0] (big-endian) hot-patched into [31:0]
 000013                     beat_buf[3] <= {tmpl_rd_b3, {8'h0, latch_shares}};
        
                            // Beats 4-5: static from template
 000013                     beat_buf[4] <= tmpl_rd_b4;
 000013                     beat_buf[5] <= tmpl_rd_b5;
        
 000013                     order_token <= order_token + 64'h1;
 000013                     beat_cnt    <= 3'h0;
 000013                     state       <= S_SEND;
                        end
        
                        // --------------------------------------------------------
 000078                 S_SEND: begin
~000078                     if (m_axis_tready) begin
 000065                         if (beat_cnt == 3'h5) begin
 000013                             m_axis_tvalid <= 1'b0;
 000013                             m_axis_tlast  <= 1'b0;
 000013                             state         <= S_IDLE;
 000065                         end else begin
                                    // Select next beat; cap index to avoid static ARRAYOOB
 000065                             m_axis_tdata  <= beat_buf[beat_cnt < 3'h5
 000065                                                       ? beat_cnt + 3'h1
                                                              : 3'h1];
 000065                             m_axis_tkeep  <= 8'hFF;
 000065                             m_axis_tlast  <= (beat_cnt == 3'h4);
 000065                             beat_cnt      <= beat_cnt + 3'h1;
                                end
                            end
                            // backpressure counted in separate always_ff above
                        end
        
                        /* verilator coverage_off */
                        default: state <= S_IDLE;
                        /* verilator coverage_on */
        
                    endcase
                end
            end
        
        endmodule
        
