// weight_mem.sv — Simple single-port SRAM for weight storage
//
// Write port: address + data + write-enable (for AXI4-Lite loads)
// Read port: address → bfloat16 weight out (one per cycle)

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module weight_mem #(
    parameter int DEPTH = FEATURE_VEC_LEN
)(
    input  logic                       clk,
    input  logic                       rst,

    // Write port (from AXI4-Lite)
    input  logic [$clog2(DEPTH)-1:0]   wr_addr,
    input  bfloat16_t                  wr_data,
    input  logic                       wr_en,

    // Read port (to dot-product engine)
    input  logic [$clog2(DEPTH)-1:0]   rd_addr,
    output bfloat16_t                  rd_data
);

    bfloat16_t mem [DEPTH];

    // Write
    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // Read (synchronous, 1-cycle latency)
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_data <= '0;
        end else begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule
