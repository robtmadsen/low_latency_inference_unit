//      // verilator_coverage annotation
        // moldupp64_strip.sv — MoldUDP64 header stripper + sequence-number validator
        //
        // Strips the 20-byte MoldUDP64 header from the UDP payload stream and
        // forwards only the clean in-order ITCH payload downstream.
        //
        // MoldUDP64 header layout (network byte order, big-endian):
        //   Offset  0–9   Session        (10 bytes)
        //   Offset 10–17  Sequence Num   (8 bytes, uint64 BE)
        //   Offset 18–19  Message Count  (2 bytes, uint16 BE)
        //   Offset 20+    ITCH messages
        //
        // At 8 bytes/beat (64-bit AXI4-Stream):
        //   Beat 0: header bytes  0–7   (session[7:0])
        //   Beat 1: header bytes  8–15  (session[9:8] + seq_num[5:0])
        //   Beat 2: header bytes 16–19 + ITCH bytes 0–3
        //            → seq_num[7:6] in tdata[15:0], msg_count[15:0] in tdata[31:16]
        //            → ITCH bytes 0–3 in tdata[63:32]
        //   Beat 3+: remainder of ITCH payload
        //
        // The first ITCH output beat must be 64-bit aligned; the four bytes from
        // the upper half of beat 2 are staged and assembled with the lower four
        // bytes of beat 3 into the first full output beat.
        //
        // Drop policy:
        //   If seq_num != expected_seq_num when the header is assembled, all
        //   remaining beats (including the ITCH portion of beat 2) are silently
        //   consumed and dropped_datagrams increments.  expected_seq_num is NOT
        //   advanced on a drop (gap recorded but not filled).
        //
        // Domain: 156.25 MHz network clock (clk_156 in kc705_top).
        
        /* verilator lint_off IMPORTSTAR */
        import lliu_pkg::*;
        /* verilator lint_on IMPORTSTAR */
        
        module moldupp64_strip (
            input  logic        clk,
            input  logic        rst,
        
            // Input: UDP payload stream (includes MoldUDP64 header)
            input  logic [63:0] s_tdata,
            input  logic [7:0]  s_tkeep,
            input  logic        s_tvalid,
            input  logic        s_tlast,
            output logic        s_tready,
        
            // Output: stripped ITCH stream only
            output logic [63:0] m_tdata,
            output logic [7:0]  m_tkeep,
            output logic        m_tvalid,
            output logic        m_tlast,
            input  logic        m_tready,
        
            // Sequence number output (sampled when seq_valid pulses)
            output logic [63:0] seq_num,
            output logic [15:0] msg_count,
            output logic        seq_valid,   // 1-cycle pulse when seq_num/msg_count captured
        
            // Gap detection counters (AXI4-Lite readable via kc705_top)
            // (* keep = "true" *) attributes prevent synthesis pruning
            (* keep = "true" *) output logic [31:0] dropped_datagrams,
            (* keep = "true" *) output logic [63:0] expected_seq_num
        );
        
            // ---------------------------------------------------------------
            // State machine
            // ---------------------------------------------------------------
            typedef enum logic [2:0] {
                S_HEADER_B0    = 3'd0,  // consume beat 0 (session bytes 7:0)
                S_HEADER_B1    = 3'd1,  // consume beat 1 (session[9:8] + seq_num[5:0])
                S_HEADER_B2    = 3'd2,  // consume beat 2 (seq_num[7:6] + msg_count + ITCH[3:0])
                S_PAYLOAD      = 3'd3,  // forward payload beats
                S_DROP         = 3'd4,  // consume & discard remainder of datagram
                S_FLUSH_SHORT  = 3'd5   // short datagram: output staged 4 ITCH bytes and return
            } state_t;
        
            state_t state, state_next;
        
            // Header field assembly registers
            logic [63:0] seq_num_r,   seq_num_next;
            logic [15:0] msg_count_r, msg_count_next;
        
            // Staging register: holds the upper 4 bytes of beat 2 (first ITCH bytes)
            // so they can be assembled with the lower 4 bytes of beat 3.
            logic [31:0] stage_hi,     stage_hi_next;   // upper 32 bits of output beat
            logic [3:0]  stage_hi_keep,stage_hi_keep_next;
            logic        stage_hi_valid, stage_hi_valid_next;
        
            // Decode the final two sequence-number bytes and the msg_count field
            // directly from beat 2 so the same values drive both state decisions
            // and the registered expected-sequence update.
            logic [63:0] header_seq_num_b2;
            logic [15:0] header_msg_count_b2;
            logic        header_in_order_b2;
            logic        header_b0_valid;
            logic        header_b1_valid;
            logic        header_b2_valid;
            logic        header_accept_b2;
        
            assign header_seq_num_b2   = {seq_num_r[63:16], tdata_byte(s_tdata, 0), tdata_byte(s_tdata, 1)};
            assign header_msg_count_b2 = {tdata_byte(s_tdata, 2), tdata_byte(s_tdata, 3)};
            assign header_in_order_b2  = (header_seq_num_b2 === expected_seq_num);
            assign header_b0_valid     = (s_tkeep == 8'hFF);
            assign header_b1_valid     = (s_tkeep == 8'hFF);
            assign header_b2_valid     = (s_tkeep[3:0] == 4'hF);
            assign header_accept_b2    = (state == S_HEADER_B2) && s_tvalid && header_b2_valid;
        
            // ---------------------------------------------------------------
            // Combinational next-state / output logic
            // ---------------------------------------------------------------
 7806611     always_comb begin
 7806611         state_next          = state;
 7806611         seq_num_next        = seq_num_r;
 7806611         msg_count_next      = msg_count_r;
 7806611         stage_hi_next       = stage_hi;
 7806611         stage_hi_keep_next  = stage_hi_keep;
 7806611         stage_hi_valid_next = stage_hi_valid;
        
 7806611         s_tready  = 1'b0;
 7806611         m_tdata   = '0;
 7806611         m_tkeep   = '0;
 7806611         m_tvalid  = 1'b0;
 7806611         m_tlast   = 1'b0;
 7806611         seq_valid = 1'b0;
        
 7806611         case (state)
                    // ----------------------------------------------------------
                    // Beat 0: session bytes [7:0] — consume silently
                    // ----------------------------------------------------------
 7790585             S_HEADER_B0: begin
 7790585                 s_tready = 1'b1;
 7787775                 if (s_tvalid) begin
 002801                     if (s_tlast || !header_b0_valid) begin
                                // Truncated/malformed datagram ended before full header.
                                // Re-arm parser at the next datagram boundary.
 000009                         stage_hi_valid_next = 1'b0;
 000009                         state_next          = S_HEADER_B0;
 002801                     end else begin
                                // Nothing to capture from beat 0; just advance
 002801                         state_next = S_HEADER_B1;
                            end
                        end
                    end
        
                    // ----------------------------------------------------------
                    // Beat 1: session[9:8] in tdata[15:0] (BE), seq_num[5:0] in tdata[63:16]
                    // Memory layout (big-endian over network, received LSB-first on AXI):
                    //   tdata[7:0]   = session byte 8
                    //   tdata[15:8]  = session byte 9
                    //   tdata[23:16] = seq_num byte 0  (MSB of seq_num in wire order)
                    //   tdata[31:24] = seq_num byte 1
                    //   tdata[39:32] = seq_num byte 2
                    //   tdata[47:40] = seq_num byte 3
                    //   tdata[55:48] = seq_num byte 4
                    //   tdata[63:56] = seq_num byte 5
                    // ----------------------------------------------------------
 002837             S_HEADER_B1: begin
 002837                 s_tready = 1'b1;
 002801                 if (s_tvalid) begin
 002774                     if (s_tlast || !header_b1_valid) begin
                                // Truncated/malformed datagram before beat 2.
 000027                         stage_hi_valid_next = 1'b0;
 000027                         state_next          = S_HEADER_B0;
 002774                     end else begin
                                // Capture upper 6 bytes of seq_num (bytes 0–5 of the 8-byte field)
 002774                         seq_num_next[63:16] = {tdata_byte(s_tdata, 2),
 002774                                                tdata_byte(s_tdata, 3),
 002774                                                tdata_byte(s_tdata, 4),
 002774                                                tdata_byte(s_tdata, 5),
 002774                                                tdata_byte(s_tdata, 6),
 002774                                                tdata_byte(s_tdata, 7)};
 002774                         state_next = S_HEADER_B2;
                            end
                        end
                    end
        
                    // ----------------------------------------------------------
                    // Beat 2: seq_num bytes [7:6] in tdata[15:0],
                    //         msg_count[15:0]    in tdata[31:16],
                    //         ITCH bytes [3:0]   in tdata[63:32]
                    //   tdata[7:0]   = seq_num byte 6
                    //   tdata[15:8]  = seq_num byte 7  (LSB)
                    //   tdata[23:16] = msg_count byte 0 (MSB)
                    //   tdata[31:24] = msg_count byte 1 (LSB)
                    //   tdata[63:32] = ITCH payload bytes 0–3
                    // ----------------------------------------------------------
 002750             S_HEADER_B2: begin
 002750                 s_tready = 1'b1;
~002750                 if (s_tvalid) begin
 002705                     if (!header_b2_valid) begin
                                // Missing required header bytes [16:19] on beat 2.
                                // Drop remainder and resync at next frame boundary.
 000045                         stage_hi_valid_next = 1'b0;
~000045                         if (s_tlast) begin
 000045                             state_next = S_HEADER_B0;
%000000                         end else begin
%000000                             state_next = S_DROP;
                                end
 002705                     end else begin
                                // Complete seq_num assembly
 002705                         seq_num_next   = header_seq_num_b2;
 002705                         msg_count_next = header_msg_count_b2;
        
 002625                         if (header_in_order_b2) begin
                                    // In-order datagram: pulse seq_valid and stage ITCH bytes 0–3
 002625                             seq_valid           = 1'b1;  // notify CDC regs (in-order only)
 002625                             stage_hi_next       = s_tdata[63:32];
 002625                             stage_hi_keep_next  = s_tkeep[7:4];
 002625                             stage_hi_valid_next = 1'b1;
 002616                             if (s_tlast) begin
                                        // Short datagram: all ITCH bytes are in beat 2's upper half.
                                        // Flush them in one output beat without entering S_PAYLOAD.
 000009                                 state_next = S_FLUSH_SHORT;
 002616                             end else begin
 002616                                 state_next = S_PAYLOAD;
                                    end
 000080                         end else begin
                                    // Out-of-order: drop the remainder (seq_valid stays 0)
 000080                             stage_hi_valid_next = 1'b0;
~000080                             if (s_tlast) begin
                                        // Short OOO datagram: last beat already consumed here.
                                        // The drop counter is incremented in the sequential block.
%000000                                 state_next = S_HEADER_B0;
 000080                             end else begin
 000080                                 state_next = S_DROP;
                                    end
                                end
                            end
                        end
                    end
        
                    // ----------------------------------------------------------
                    // PAYLOAD: assemble 64-bit output beats from staged upper
                    // half (ITCH bytes 0–3 from beat 2) + incoming lower half.
                    // ----------------------------------------------------------
 010351             S_PAYLOAD: begin
 010351                 s_tready = m_tready;
        
 010351                 if (s_tvalid && stage_hi_valid) begin
                            // Assemble: [stage_hi (beat N-1 upper)] + [beat N lower]
 010351                     m_tdata  = {s_tdata[31:0], stage_hi};
 010351                     m_tkeep  = {s_tkeep[3:0],  stage_hi_keep};
 010351                     m_tvalid = 1'b1;
 010351                     m_tlast  = s_tlast;
        
~010351                     if (m_tready) begin
                                // Advance: stage the upper half of this beat for the next output
 010351                         stage_hi_next      = s_tdata[63:32];
 010351                         stage_hi_keep_next = s_tkeep[7:4];
                                // If tlast and upper half is all-zero keep, no more output needed
 010351                         stage_hi_valid_next = ~s_tlast || (s_tkeep[7:4] != 4'b0);
        
 007926                         if (s_tlast) begin
                                    // End of datagram: advance expected sequence number
 002425                             state_next = S_HEADER_B0;
                                end
                            end
%000000                 end else if (!stage_hi_valid) begin
                            // No staged data — shouldn't happen in normal flow; return to header
%000000                     state_next = S_HEADER_B0;
                        end
                    end
        
                    // ----------------------------------------------------------
                    // DROP: consume and discard all remaining beats
                    // ----------------------------------------------------------
 000079             S_DROP: begin
 000079                 s_tready = 1'b1;
 000079                 m_tvalid = 1'b0;
~000079                 if (s_tvalid) begin
 000079                     state_next = S_HEADER_B0;
                        end
                    end
        
                    // ----------------------------------------------------------
                    // FLUSH_SHORT: output the 4 ITCH bytes staged from beat 2
                    // when the datagram ended at beat 2 (short datagram path).
                    // ----------------------------------------------------------
 000009             S_FLUSH_SHORT: begin
 000009                 m_tdata  = {32'b0, stage_hi};        // ITCH bytes 0–3 in tdata[31:0]
 000009                 m_tkeep  = {4'b0,  stage_hi_keep};   // 4 valid bytes
 000009                 m_tvalid = 1'b1;
 000009                 m_tlast  = 1'b1;
~000009                 if (m_tready) begin
 000009                     stage_hi_valid_next = 1'b0;
 000009                     state_next          = S_HEADER_B0;
                        end
                    end
        
                    /* verilator coverage_off */
                    default: state_next = S_HEADER_B0;
                    /* verilator coverage_on */
                endcase
            end
        
            // ---------------------------------------------------------------
            // Single sequential block — all registered state in one always_ff.
            // Keeping seq-tracking (expected_seq_num, dropped_datagrams) in the
            // same block as the state/field registers avoids simulation-ordering
            // issues where separate always_ff blocks see each other's NBAs and
            // evaluate conditions against a post-transition state value.
            // ---------------------------------------------------------------
 859379     always_ff @(posedge clk) begin
 857900         if (rst) begin
 001479             state             <= S_HEADER_B0;
 001479             seq_num_r         <= '0;
 001479             msg_count_r       <= '0;
 001479             stage_hi          <= '0;
 001479             stage_hi_keep     <= '0;
 001479             stage_hi_valid    <= 1'b0;
 001479             expected_seq_num  <= 64'd1;   // MoldUDP64 sequence numbers start at 1
 001479             dropped_datagrams <= 32'd0;
 857900         end else begin
 857900             state          <= state_next;
 857900             seq_num_r      <= seq_num_next;
 857900             msg_count_r    <= msg_count_next;
 857900             stage_hi       <= stage_hi_next;
 857900             stage_hi_keep  <= stage_hi_keep_next;
 857900             stage_hi_valid <= stage_hi_valid_next;
        
                    // Advance expected_seq_num when beat 2 is accepted in-order.
                    // Use the decoded beat-2 header fields directly so advancement
                    // does not depend on intermediate next-state temporaries.
 857627             if (header_accept_b2) begin
 000265                 if (header_in_order_b2) begin
 000265                     expected_seq_num <= header_seq_num_b2 + 64'd1;
 000008                 end else begin
                            // Increment drop counter once per out-of-order datagram
                            // when the beat-2 header decision is made.
~000008                     if (dropped_datagrams != 32'hFFFF_FFFF)
 000008                         dropped_datagrams <= dropped_datagrams + 32'd1;
                        end
                    end
                end
            end
        
            // ---------------------------------------------------------------
            // seq_num and msg_count outputs
            //   msg_count: combinational during the B2 beat so the SVA's $past(msg_count)
            //   sees the freshly assembled value in the same cycle seq_valid fires.
            //   After the clock edge it reverts to the stable registered value.
            // ---------------------------------------------------------------
            assign seq_num   = seq_num_r;
 7803861     assign msg_count = (state == S_HEADER_B2 && s_tvalid) ? header_msg_count_b2 : msg_count_r;
        
            // ---------------------------------------------------------------
            // Helper function: extract byte N from a 64-bit word (big-endian)
            //   byte 0 = tdata[7:0], byte 1 = tdata[15:8], ...
            // ---------------------------------------------------------------
 31243088     function automatic logic [7:0] tdata_byte(
                input logic [63:0] data,
                input int          idx
            );
 31243088         return data[idx*8 +: 8];
            endfunction
        
        endmodule
        
