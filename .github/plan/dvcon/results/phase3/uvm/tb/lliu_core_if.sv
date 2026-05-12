interface lliu_core_if (input logic clk);
    logic        rst;
    logic [15:0] features [4];
    logic        features_valid;
    logic [1:0]  wgt_wr_addr;
    logic [15:0] wgt_wr_data;
    logic        wgt_wr_en;
    logic [31:0] result;
    logic        result_valid;
    logic [31:0] result_out;
    logic        result_ready;
endinterface
