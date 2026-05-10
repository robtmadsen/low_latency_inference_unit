// itch_if.sv — Interface for itch_field_extract DUT
interface itch_if (input logic clk);
    logic         rst;
    logic [287:0] msg_data;
    logic         msg_valid;
    logic [7:0]   message_type;
    logic [63:0]  order_ref;
    logic         side;
    logic [31:0]  price;
    logic [63:0]  stock;
    logic         fields_valid;
endinterface
