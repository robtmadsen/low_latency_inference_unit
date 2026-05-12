//      // verilator_coverage annotation
        // output_buffer.sv — Single float32 register for inference result
        //
        // Latches result on result_valid strobe from dot-product engine.
        // Presents value for AXI4-Lite readout.
        
        /* verilator lint_off IMPORTSTAR */
        import lliu_pkg::*;
        /* verilator lint_on IMPORTSTAR */
        
        module output_buffer (
 002066     input  logic     clk,
 000016     input  logic     rst,
        
            // From dot-product engine
%000002     input  float32_t result_in,
%000001     input  logic     result_valid,
        
            // To AXI4-Lite read path
%000001     output float32_t result_out,
%000001     output logic     result_ready  // indicates a valid result is available
        );
        
%000001     logic result_ready_reg;
        
 002066     always_ff @(posedge clk) begin
 000080         if (rst) begin
 000080             result_out  <= '0;
 000080             result_ready_reg <= 1'b0;
~001985         end else if (result_valid && !result_ready_reg) begin
%000001             result_out  <= result_in;
%000001             result_ready_reg <= 1'b1;
                end
            end
        
            assign result_ready = result_ready_reg;
        
        endmodule
        
