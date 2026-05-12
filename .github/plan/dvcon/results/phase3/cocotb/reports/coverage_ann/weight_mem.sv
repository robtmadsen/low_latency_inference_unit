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
 002066     input  logic                       clk,
 000016     input  logic                       rst,
        
            // Write port (from AXI4-Lite)
 000240     input  logic [$clog2(DEPTH)-1:0]   wr_addr,
~000024     input  bfloat16_t                  wr_data,
 000015     input  logic                       wr_en,
        
            // Read port (to dot-product engine)
 000195     input  logic [$clog2(DEPTH)-1:0]   rd_addr,
~000017     output bfloat16_t                  rd_data
        );
        
            bfloat16_t mem [DEPTH];
        
            // Write
 002066     always_ff @(posedge clk) begin
 001586         if (wr_en) begin
 000480             mem[wr_addr] <= wr_data;
                end
            end
        
            // Read port
            assign rd_data = mem[rd_addr];
        
        endmodule
        
