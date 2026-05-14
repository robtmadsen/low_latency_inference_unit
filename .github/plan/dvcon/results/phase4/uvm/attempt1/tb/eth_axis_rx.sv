// eth_axis_rx.sv — Simulation stub: streaming Ethernet header stripper
// Always accepts input (s_axis_tready=1). Uses internal FIFO to decouple
// input from output. Strips 14-byte Ethernet header with 6-byte realignment,
// matching the real Forencich module's always-ready behavior.

module eth_axis_rx #(
    parameter DATA_WIDTH  = 64,
    parameter KEEP_ENABLE = 1,
    parameter KEEP_WIDTH  = DATA_WIDTH/8
)(
    input  wire                   clk,
    input  wire                   rst,

    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]  s_axis_tkeep,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire                   s_axis_tuser,
    /* verilator lint_on UNUSEDSIGNAL */

    output reg                    m_eth_hdr_valid,
    input  wire                   m_eth_hdr_ready,
    output reg  [47:0]            m_eth_dest_mac,
    output reg  [47:0]            m_eth_src_mac,
    output reg  [15:0]            m_eth_type,

    output reg  [DATA_WIDTH-1:0]  m_eth_payload_axis_tdata,
    output reg  [KEEP_WIDTH-1:0]  m_eth_payload_axis_tkeep,
    output reg                    m_eth_payload_axis_tvalid,
    input  wire                   m_eth_payload_axis_tready,
    output reg                    m_eth_payload_axis_tlast,
    output reg                    m_eth_payload_axis_tuser,

    output wire                   busy,
    output wire                   error_header_early_termination
);

    assign s_axis_tready = 1'b1;
    assign error_header_early_termination = 1'b0;

    // ---------------------------------------------------------------
    // Input FIFO — always accepts, decouples MAC timing from processing
    // ---------------------------------------------------------------
    localparam FIFO_AW = 9;
    localparam FIFO_SZ = 1 << FIFO_AW;

    reg [72:0] fifo_mem [0:FIFO_SZ-1];
    reg [FIFO_AW-1:0] wr_ptr, rd_ptr;

    wire fifo_empty = (wr_ptr == rd_ptr);

    always_ff @(posedge clk) begin
        if (rst)
            wr_ptr <= '0;
        else if (s_axis_tvalid) begin
            fifo_mem[wr_ptr] <= {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
            wr_ptr <= wr_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
        end
    end

    wire [63:0] f_tdata = fifo_mem[rd_ptr][63:0];
    wire [7:0]  f_tkeep = fifo_mem[rd_ptr][71:64];
    wire        f_tlast = fifo_mem[rd_ptr][72];
    wire        f_valid = !fifo_empty;

    // ---------------------------------------------------------------
    // Streaming header stripper with 2-byte (16-bit) realignment
    //
    // Ethernet header = 14 bytes = 1 full beat + 6 bytes of beat 1.
    // Beat 0: dest_mac[5:0] + src_mac[1:0]  (consumed, no output)
    // Beat 1: src_mac[5:2] + eth_type + 2 payload bytes (header extracted,
    //         2 payload bytes staged)
    // Beat 2+: combine staged 2 bytes + 6 bytes from current beat → output
    // ---------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE    = 2'd0,
        S_HDR1    = 2'd1,
        S_PAYLOAD = 2'd2,
        S_FLUSH   = 2'd3
    } state_t;

    state_t state;
    reg [15:0] staged_data;
    reg [1:0]  staged_keep;
    reg [47:0] dest_mac_cap;
    reg [15:0] src_mac_hi;

    wire can_advance = (state == S_IDLE || state == S_HDR1) ||
                       (state == S_PAYLOAD &&
                        (!m_eth_payload_axis_tvalid || m_eth_payload_axis_tready));

    assign busy = (state != S_IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            rd_ptr    <= '0;
            m_eth_hdr_valid           <= 1'b0;
            m_eth_payload_axis_tvalid <= 1'b0;
            m_eth_payload_axis_tlast  <= 1'b0;
            m_eth_payload_axis_tuser  <= 1'b0;
            m_eth_dest_mac            <= '0;
            m_eth_src_mac             <= '0;
            m_eth_type                <= '0;
            m_eth_payload_axis_tdata  <= '0;
            m_eth_payload_axis_tkeep  <= '0;
            staged_data  <= '0;
            staged_keep  <= '0;
            dest_mac_cap <= '0;
            src_mac_hi   <= '0;
        end else begin
            // Header handshake
            if (m_eth_hdr_valid && m_eth_hdr_ready)
                m_eth_hdr_valid <= 1'b0;

            // Payload handshake
            if (m_eth_payload_axis_tvalid && m_eth_payload_axis_tready) begin
                m_eth_payload_axis_tvalid <= 1'b0;
                m_eth_payload_axis_tlast  <= 1'b0;
            end

            case (state)
                // Beat 0: capture dest_mac (6B) + src_mac partial (2B)
                S_IDLE: begin
                    if (f_valid) begin
                        dest_mac_cap <= {f_tdata[7:0],   f_tdata[15:8],
                                         f_tdata[23:16], f_tdata[31:24],
                                         f_tdata[39:32], f_tdata[47:40]};
                        src_mac_hi   <= {f_tdata[55:48], f_tdata[63:56]};
                        rd_ptr <= rd_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
                        state  <= f_tlast ? S_IDLE : S_HDR1;
                    end
                end

                // Beat 1: complete header, stage first 2 payload bytes
                S_HDR1: begin
                    if (f_valid) begin
                        m_eth_dest_mac  <= dest_mac_cap;
                        m_eth_src_mac   <= {src_mac_hi,
                                            f_tdata[7:0],   f_tdata[15:8],
                                            f_tdata[23:16], f_tdata[31:24]};
                        m_eth_type      <= {f_tdata[39:32], f_tdata[47:40]};
                        m_eth_hdr_valid <= 1'b1;

                        staged_data <= f_tdata[63:48];
                        staged_keep <= f_tkeep[7:6];
                        rd_ptr <= rd_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};

                        if (f_tlast)
                            state <= (f_tkeep[7:6] != 2'b00) ? S_FLUSH : S_IDLE;
                        else
                            state <= S_PAYLOAD;
                    end
                end

                // Streaming payload: realign 2+6 bytes per beat
                S_PAYLOAD: begin
                    if (f_valid && can_advance) begin
                        m_eth_payload_axis_tdata  <= {f_tdata[47:0], staged_data};
                        m_eth_payload_axis_tkeep  <= {f_tkeep[5:0], staged_keep};
                        m_eth_payload_axis_tvalid <= 1'b1;
                        m_eth_payload_axis_tuser  <= 1'b0;

                        staged_data <= f_tdata[63:48];
                        staged_keep <= f_tkeep[7:6];
                        rd_ptr <= rd_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};

                        if (f_tlast) begin
                            if (f_tkeep[7:6] != 2'b00) begin
                                m_eth_payload_axis_tlast <= 1'b0;
                                state <= S_FLUSH;
                            end else begin
                                m_eth_payload_axis_tlast <= 1'b1;
                                state <= S_IDLE;
                            end
                        end else
                            m_eth_payload_axis_tlast <= 1'b0;
                    end
                end

                // Flush remaining 2 staged bytes
                S_FLUSH: begin
                    if (!m_eth_payload_axis_tvalid || m_eth_payload_axis_tready) begin
                        m_eth_payload_axis_tdata  <= {48'b0, staged_data};
                        m_eth_payload_axis_tkeep  <= {6'b0, staged_keep};
                        m_eth_payload_axis_tvalid <= 1'b1;
                        m_eth_payload_axis_tlast  <= 1'b1;
                        m_eth_payload_axis_tuser  <= 1'b0;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
