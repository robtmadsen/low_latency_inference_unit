// latency_histogram.sv — 32-bin cycle-count latency histogram
/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */
/* verilator lint_off UNUSEDSIGNAL */
module latency_histogram (
    input  logic        clk,
    input  logic        rst,
    input  logic [73:0] t_start,
    input  logic        t_start_valid,
    input  logic [73:0] t_end,
    input  logic        t_end_valid,
    input  logic [4:0]  axil_bin_addr,
    output logic [31:0] axil_bin_data,
    input  logic        axil_clear,
    output logic [31:0] overflow_bin
);
    (* ram_style = "distributed" *) logic [31:0] hist_bins [0:31];
    logic [31:0] overflow_r;
    logic [73:0] t_start_r;
    logic        t_start_held;

    always_ff @(posedge clk) begin
        if (rst) begin
            t_start_held <= 1'b0;
            t_start_r    <= '0;
            overflow_r   <= '0;
            for (int i = 0; i < 32; i++) hist_bins[i] <= '0;
        end else begin
            if (axil_clear) begin
                for (int i = 0; i < 32; i++) hist_bins[i] <= '0;
                overflow_r <= '0;
            end
            if (t_start_valid) begin
                t_start_r    <= t_start;
                t_start_held <= 1'b1;
            end
            if (t_end_valid && t_start_held) begin
                automatic logic [9:0] delta;
                delta = t_end[9:0] - t_start_r[9:0];
                t_start_held <= 1'b0;
                if (delta > 10'd31)
                    overflow_r <= overflow_r + 1;
                else
                    hist_bins[delta[4:0]] <= hist_bins[delta[4:0]] + 1;
            end
        end
    end
    assign axil_bin_data = hist_bins[axil_bin_addr];
    assign overflow_bin  = overflow_r;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
