//      // verilator_coverage annotation
        // ptp_core.sv — PTP v2 timestamp core (Phase 1: free-running counter)
        /* verilator lint_off IMPORTSTAR */
        import lliu_pkg::*;
        /* verilator lint_on IMPORTSTAR */
        module ptp_core (
            input  logic        clk,
            input  logic        rst,
            output logic        ptp_sync_pulse,
            output logic [63:0] ptp_epoch,
            output logic [63:0] ptp_counter
        );
            logic [63:0] ptp_counter_r;
            logic [63:0] ptp_epoch_r;
            logic [9:0]  sync_cnt;
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             ptp_counter_r  <= '0;
 002822             ptp_epoch_r    <= '0;
 002822             sync_cnt       <= '0;
 002822             ptp_sync_pulse <= 1'b0;
 1715919         end else begin
 1715919             ptp_counter_r  <= ptp_counter_r + 1;
 1715919             ptp_sync_pulse <= (sync_cnt == 10'd1022);
 1714276             if (sync_cnt == 10'd1023) begin
 001643                 ptp_epoch_r <= ptp_counter_r;
 001643                 sync_cnt    <= '0;
 1714276             end else begin
 1714276                 sync_cnt <= sync_cnt + 1;
                    end
                end
            end
            assign ptp_epoch   = ptp_epoch_r;
            assign ptp_counter = ptp_counter_r;
        endmodule
        
