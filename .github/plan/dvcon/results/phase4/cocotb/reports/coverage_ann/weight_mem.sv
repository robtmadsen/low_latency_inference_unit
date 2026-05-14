//      // verilator_coverage annotation
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
 13749928     always_ff @(posedge clk) begin
 13731176         if (wr_en) begin
 018752             mem[wr_addr] <= wr_data;
                end
            end
        
            // Read (synchronous, 1-cycle latency)
 13749928     always_ff @(posedge clk) begin
 13727352         if (rst) begin
 022576             rd_data <= '0;
 13727352         end else begin
 13727352             rd_data <= mem[rd_addr + 1];
                end
            end
        
        endmodule
        
