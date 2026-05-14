//      // verilator_coverage annotation
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
 10312446     always_ff @(posedge clk) begin
 10295514         if (rst) begin
 016932             local_sub_cnt   <= '0;
 016932             epoch_latch     <= '0;
 016932             timestamp_out   <= '0;
 016932             timestamp_valid <= 1'b0;
 10295514         end else begin
 10295514             timestamp_valid <= 1'b0;
 10285656             if (ptp_sync_pulse) begin
 009858                 local_sub_cnt <= '0;
 009858                 epoch_latch   <= ptp_epoch;
 10285656             end else begin
 10285656                 local_sub_cnt <= local_sub_cnt + 1;
                    end
 10293201             if (tap_event) begin
 002313                 timestamp_out   <= {epoch_latch, local_sub_cnt};
 002313                 timestamp_valid <= 1'b1;
                    end
                end
            end
        endmodule
        
