// kc705_ctrl_if.sv — KC705 block-test control interface
//
// Carries the extra DUT ports that are not in the standard AXI4-S /
// AXI4-Lite interfaces.  One instance in tb_top is registered in the
// UVM config DB so that block-level tests (MOLDUPP64_DUT, SYMFILTER_DUT,
// DROPFULL_DUT) can access DUT-specific signals without adding a new
// agent per pin.
//
// Signals are grouped by which block-level DUT uses them.  In any given
// simulation only one group will be actively connected; the remainder
// float / stay at initial values.

`timescale 1ns/1ps

interface kc705_ctrl_if (
    input logic clk,
    input logic rst
);

    // ----------------------------------------------------------------
    // moldupp64_strip output stream + status signals
    // ----------------------------------------------------------------
    logic [63:0] m_tdata;
    logic [7:0]  m_tkeep;
    logic        m_tvalid;
    logic        m_tlast;
    logic        m_tready; // test drives this (back-pressure host)

    logic [63:0] seq_num;
    logic [15:0] msg_count;
    logic        seq_valid;
    logic [31:0] dropped_datagrams;
    logic [63:0] expected_seq_num;

    // ----------------------------------------------------------------
    // symbol_filter ports (CAM write + lookup)
    // ----------------------------------------------------------------
    logic [5:0]  cam_wr_index;
    logic [63:0] cam_wr_data;
    logic        cam_wr_valid;
    logic        cam_wr_en_bit;

    logic [63:0] stock;         // test drives (8-char ASCII ticker, big-endian)
    logic        stock_valid;   // test drives (1-cycle pulse)
    logic        watchlist_hit; // DUT drives (registered output, 1 cycle later)

    // ----------------------------------------------------------------
    // eth_axis_rx_wrap extra signals
    // ----------------------------------------------------------------
    logic        fifo_almost_full;      // test drives (simulates FIFO level)

    logic [63:0] eth_payload_tdata;
    logic [7:0]  eth_payload_tkeep;
    logic        eth_payload_tvalid;
    logic        eth_payload_tlast;
    logic        eth_payload_tready;    // test drives (output side back-pressure)

    logic [31:0] dropped_frames;        // DUT drives

    // ----------------------------------------------------------------
    // s_tkeep — input side tkeep for DUTs that need it
    // (moldupp64_strip.s_tkeep, eth_axis_rx_wrap.mac_rx_tkeep)
    // The sequence always sends full 64-bit beats (tkeep=0xFF) so this
    // is tied to 8'hFF in tb_top for MOLDUPP64_DUT.
    // For DROPFULL_DUT, the test can vary it to test partial last beat.
    // ----------------------------------------------------------------
    logic [7:0]  s_tkeep;

    // ----------------------------------------------------------------
    // kc705_top system-level observation / control signals
    // (KC705_TOP_DUT context only; float in all other DUT contexts)
    // ----------------------------------------------------------------
    logic        cpu_reset;          // test drives, DUT reset
    // OUCH 5.0 output stream — DUT drives, test controls m_axis_tready
    logic [63:0] m_axis_tdata;       // DUT drives
    logic [7:0]  m_axis_tkeep;       // DUT drives
    logic        m_axis_tvalid;      // DUT drives — proxy for "inference result valid"
    logic        m_axis_tlast;       // DUT drives
    logic        m_axis_tready;      // test drives (backpressure control)
    logic        fifo_rd_tvalid;     // DUT drives, first ITCH beat from CDC FIFO

    // ----------------------------------------------------------------
    // Clocking block — driver side (test writes these)
    // ----------------------------------------------------------------
    clocking driver_cb @(posedge clk);
        default input #1step output #0;
        output m_tready;
        output cam_wr_index;
        output cam_wr_data;
        output cam_wr_valid;
        output cam_wr_en_bit;
        output stock;
        output stock_valid;
        output fifo_almost_full;
        output eth_payload_tready;
        output s_tkeep;
        output cpu_reset;
        output m_axis_tready;  // drive backpressure for tx_backpressure tests
    endclocking

    // ----------------------------------------------------------------
    // Clocking block — monitor side (test reads these)
    // ----------------------------------------------------------------
    clocking monitor_cb @(posedge clk);
        default input #1step;
        input m_tdata;
        input m_tkeep;
        input m_tvalid;
        input m_tlast;
        input seq_num;
        input msg_count;
        input seq_valid;
        input dropped_datagrams;
        input expected_seq_num;
        input watchlist_hit;
        input eth_payload_tdata;
        input eth_payload_tkeep;
        input eth_payload_tvalid;
        input eth_payload_tlast;
        input dropped_frames;
        input m_axis_tdata;
        input m_axis_tkeep;
        input m_axis_tvalid;
        input m_axis_tlast;
        input fifo_rd_tvalid;
    endclocking

endinterface
