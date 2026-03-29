// output_buffer.sv — Single float32 register for inference result
//
// Latches result on result_valid strobe from dot-product engine.
// Presents value for AXI4-Lite readout.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module output_buffer (
    input  logic     clk,
    input  logic     rst,

    // From dot-product engine
    input  float32_t result_in,
    input  logic     result_valid,

    // To AXI4-Lite read path
    output float32_t result_out,
    output logic     result_ready  // indicates a valid result is available
);

    logic result_ready_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            result_out  <= '0;
            result_ready_reg <= 1'b0;
        end else if (result_valid) begin
            result_out  <= result_in;
            result_ready_reg <= 1'b1;
        end
    end

    assign result_ready = result_ready_reg;

endmodule
