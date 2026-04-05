// timestamp_tap.sv — Pipeline timestamp capture using PTP sync pulse
/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */
module timestamp_tap (
    input  logic        clk,
    input  logic        rst,
    input  logic        ptp_sync_pulse,
    input  logic [63:0] ptp_epoch,
    input  logic        tap_event,
    output logic [73:0] timestamp_out,
    output logic        timestamp_valid
);
    logic [9:0]  local_sub_cnt;
    logic [63:0] epoch_latch;
    always_ff @(posedge clk) begin
        if (rst) begin
            local_sub_cnt   <= '0;
            epoch_latch     <= '0;
            timestamp_out   <= '0;
            timestamp_valid <= 1'b0;
        end else begin
            timestamp_valid <= 1'b0;
            if (ptp_sync_pulse) begin
                local_sub_cnt <= '0;
                epoch_latch   <= ptp_epoch;
            end else begin
                local_sub_cnt <= local_sub_cnt + 1;
            end
            if (tap_event) begin
                timestamp_out   <= {epoch_latch, local_sub_cnt};
                timestamp_valid <= 1'b1;
            end
        end
    end
endmodule
