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
    always_ff @(posedge clk) begin
        if (rst) begin
            ptp_counter_r  <= '0;
            ptp_epoch_r    <= '0;
            sync_cnt       <= '0;
            ptp_sync_pulse <= 1'b0;
        end else begin
            ptp_counter_r  <= ptp_counter_r + 1;
            ptp_sync_pulse <= (sync_cnt == 10'd1022);
            if (sync_cnt == 10'd1023) begin
                ptp_epoch_r <= ptp_counter_r;
                sync_cnt    <= '0;
            end else begin
                sync_cnt <= sync_cnt + 1;
            end
        end
    end
    assign ptp_epoch   = ptp_epoch_r;
    assign ptp_counter = ptp_counter_r;
endmodule
