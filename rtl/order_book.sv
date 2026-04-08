// order_book.sv — BRAM-backed L3 order book for LLIU v2.0 Phase 1
//
// Resources (xc7k160tffg676-2 estimates):
//   book_mem : 500×2×16 × 56b ≈ 28 BRAM18 (inference)
//   ref_mem  : 128K × 128b ≈ 128 BRAM18   (inference)
//   bbo_*_r  : 500 × 4 × 32b + 2 × 24b = FF arrays
//
// Phase 1 BBO simplification:
//   Add  : update BBO if new order is better
//   Del/X: reset BBO to 0 if the deleted order was at the current BBO price
//   Full BBO rescan deferred to Phase 2
//
// CRC-17 polynomial: 0x1002D (CRC-17/CAN)
//
// FSM 7-state:
//   S_IDLE → S_SCAN_BOOK (Add/Add-MPID) or S_READ_REF1 (modify ops) or stay (Trade/unknown)
//   S_READ_REF1 → S_READ_REF2 → S_PROCESS → S_SCAN_BOOK → S_UPDATE → S_DONE → S_IDLE

`default_nettype none

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module order_book (
    input  logic        clk,
    input  logic        rst,
    // Parsed ITCH message (from itch_parser_v2)
    input  logic [7:0]  msg_type,
    input  logic [63:0] order_ref,
    input  logic [63:0] new_order_ref,
    input  logic [31:0] price,
/* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] shares,        // [31:24] reserved, only [23:0] used
/* verilator lint_on UNUSEDSIGNAL */
    input  logic        side,          // 1=bid, 0=ask
    input  logic [8:0]  sym_id,        // 0-499
    input  logic        fields_valid,
    // BBO combinatorial query (1-cycle FF latency)
    input  logic [8:0]  bbo_query_sym,
    output logic [31:0] bbo_bid_price,
    output logic [31:0] bbo_ask_price,
    output logic [23:0] bbo_bid_size,
    output logic [23:0] bbo_ask_size,
    // BBO update notification (1-cycle pulse)
    output logic        bbo_valid,
    output logic [8:0]  bbo_sym_id,
    // L2 book levels (registered, 1-cycle latency, follows bbo_query_sym)
    // Levels 0-3 per side in insertion order (not price-sorted in Phase 1)
    output logic [31:0] l2_bid_price [0:3],
    output logic [23:0] l2_bid_size  [0:3],
    output logic [31:0] l2_ask_price [0:3],
    output logic [23:0] l2_ask_size  [0:3],
    // Telemetry
    output logic [31:0] collision_count,
    output logic        collision_flag,
    output logic        book_ready
);

// ---------------------------------------------------------------------------
// CRC-17/CAN hash function
// ---------------------------------------------------------------------------
function automatic logic [16:0] crc17(input logic [63:0] data);
    logic [16:0] crc;
    crc = 17'h0;
    for (int i = 63; i >= 0; i--) begin
        automatic logic msb;
        msb = crc[16] ^ data[i];
        crc = {crc[15:0], 1'b0};
        if (msb) crc ^= 17'h1002D;
    end
    return crc;
endfunction

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------
// book_mem: 500 symbols × 2 sides × 16 price levels
// Entry: {price[31:0], shares[23:0]} = 56 bits
/* verilator lint_off UNOPTFLAT */
(* ram_style = "block" *) logic [55:0] book_mem [0:OB_NUM_SYMBOLS-1][0:1][0:OB_LEVELS-1];

// ref_mem: 2^17 = 131072 entries, 128 bits wide
// Layout: [127]=valid, [126:63]=order_ref(64b), [62:31]=price(32b), [30:7]=shares(24b),
//         [6]=side, [5:0]=reserved
(* ram_style = "block" *) logic [127:0] ref_mem [0:(1<<OB_REF_TABLE_BITS)-1];
/* verilator lint_on UNOPTFLAT */

// l2_cache: shadow of book_mem levels 0-3 per side per symbol.
// No ram_style → Vivado infers LUTRAM (distributed RAM).
// 500 × 2 sides × 4 levels × 56 bits = 224 Kbits ≈ 3.5 K LUTs.
// Mirrors every book_mem write where target_level < 4, enabling 8 simultaneous
// reads per cycle from the L2 query block without multi-port BRAM conflicts.
logic [55:0] l2_cache [0:OB_NUM_SYMBOLS-1][0:1][0:3];

// BBO registers — kept as flip-flops for single-cycle registered read
logic [31:0] bbo_bid_price_r [0:OB_NUM_SYMBOLS-1];
logic [31:0] bbo_ask_price_r [0:OB_NUM_SYMBOLS-1];
logic [23:0] bbo_bid_size_r  [0:OB_NUM_SYMBOLS-1];
logic [23:0] bbo_ask_size_r  [0:OB_NUM_SYMBOLS-1];

// ---------------------------------------------------------------------------
// FSM state
// ---------------------------------------------------------------------------
typedef enum logic [2:0] {
    S_IDLE      = 3'd0,
    S_READ_REF1 = 3'd1,
    S_READ_REF2 = 3'd2,
    S_PROCESS   = 3'd3,
    S_SCAN_BOOK = 3'd4,
    S_UPDATE    = 3'd5,
    S_DONE      = 3'd6
} ob_state_t;

ob_state_t state;

// ---------------------------------------------------------------------------
// Operation registers (latched in S_IDLE on fields_valid)
// ---------------------------------------------------------------------------
logic [7:0]  op_msg_type;
logic [63:0] op_order_ref;
logic [63:0] op_new_order_ref;
logic [31:0] op_price;
logic [23:0] op_shares;          // truncated to 24 bits
logic        op_side;
logic [8:0]  op_sym_id;
logic [16:0] op_hash;
logic [16:0] op_new_hash;        // CRC of new_order_ref (for Replace)

/* verilator lint_off UNUSEDSIGNAL */
logic [127:0] ref_rd_data;       // BRAM read pipeline register; [5:0] are reserved
/* verilator lint_on UNUSEDSIGNAL */
logic [16:0]  ref_rd_addr;       // registered address for BRAM read

// Scan-phase state
logic [3:0]   target_level;
logic         target_found;
logic [31:0]  op_ref_price;      // from ref entry
logic [23:0]  op_ref_shares;     // from ref entry
logic         op_ref_side;       // from ref entry

// BBO update helpers
assign book_ready = (state == S_IDLE);

// ---------------------------------------------------------------------------
// BBO registered query output
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    bbo_bid_price <= bbo_bid_price_r[bbo_query_sym];
    bbo_ask_price <= bbo_ask_price_r[bbo_query_sym];
    bbo_bid_size  <= bbo_bid_size_r[bbo_query_sym];
    bbo_ask_size  <= bbo_ask_size_r[bbo_query_sym];
end

// ---------------------------------------------------------------------------
// L2 book level registered query output (top 4 levels per side, insertion order)
// Reads from l2_cache (LUTRAM) rather than book_mem (BRAM) to avoid requiring
// 8 simultaneous read ports on a 2-port 7-series BRAM.
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    for (int k = 0; k < 4; k++) begin
        l2_bid_price[k] <= l2_cache[bbo_query_sym][1][k][55:24];
        l2_bid_size[k]  <= l2_cache[bbo_query_sym][1][k][23:0];
        l2_ask_price[k] <= l2_cache[bbo_query_sym][0][k][55:24];
        l2_ask_size[k]  <= l2_cache[bbo_query_sym][0][k][23:0];
    end
end

// ---------------------------------------------------------------------------
// Main FSM
// ---------------------------------------------------------------------------
integer bbo_init_i;

always_ff @(posedge clk) begin
    if (rst) begin
        state          <= S_IDLE;
        collision_count <= 32'h0;
        collision_flag  <= 1'b0;
        bbo_valid       <= 1'b0;
        bbo_sym_id      <= 9'h0;
        op_msg_type     <= 8'h0;
        op_order_ref    <= 64'h0;
        op_new_order_ref<= 64'h0;
        op_price        <= 32'h0;
        op_shares       <= 24'h0;
        op_side         <= 1'b0;
        op_sym_id       <= 9'h0;
        op_hash         <= 17'h0;
        op_new_hash     <= 17'h0;
        ref_rd_data     <= 128'h0;
        ref_rd_addr     <= 17'h0;
        target_level    <= 4'h0;
        target_found    <= 1'b0;
        op_ref_price    <= 32'h0;
        op_ref_shares   <= 24'h0;
        op_ref_side     <= 1'b0;
        for (bbo_init_i = 0; bbo_init_i < OB_NUM_SYMBOLS; bbo_init_i = bbo_init_i + 1) begin
            bbo_bid_price_r[bbo_init_i] <= 32'h0;
            bbo_ask_price_r[bbo_init_i] <= 32'h0;
            bbo_bid_size_r[bbo_init_i]  <= 24'h0;
            bbo_ask_size_r[bbo_init_i]  <= 24'h0;
        end
    end else begin
        // Default pulse clears
        bbo_valid      <= 1'b0;
        collision_flag <= 1'b0;

        case (state)

            // ------------------------------------------------------------------
            S_IDLE: begin
                if (fields_valid) begin
                    // Latch operation fields
                    op_msg_type      <= msg_type;
                    op_order_ref     <= order_ref;
                    op_new_order_ref <= new_order_ref;
                    op_price         <= price;
                    op_shares        <= shares[23:0];
                    op_side          <= side;
                    op_sym_id        <= sym_id;
                    op_hash          <= crc17(order_ref);
                    op_new_hash      <= crc17(new_order_ref);

                    // Route based on message type
                    case (msg_type)
                        8'h41, // 'A' Add Order
                        8'h46: // 'F' Add Order (MPID)
                            state <= S_SCAN_BOOK;

                        8'h58, // 'X' Order Cancel
                        8'h44, // 'D' Order Delete
                        8'h55, // 'U' Order Replace
                        8'h45, // 'E' Order Executed
                        8'h43: // 'C' Order Executed with Price
                            state <= S_READ_REF1;

                        default: // 'P' Trade, any unknown — no-op
                            state <= S_IDLE;
                    endcase
                end
            end

            // ------------------------------------------------------------------
            // 2-cycle BRAM read pipeline
            // ------------------------------------------------------------------
            S_READ_REF1: begin
                ref_rd_addr <= op_hash;
                state       <= S_READ_REF2;
            end

            S_READ_REF2: begin
                ref_rd_data <= ref_mem[ref_rd_addr];
                state       <= S_PROCESS;
            end

            // ------------------------------------------------------------------
            S_PROCESS: begin
                op_ref_side   <= ref_rd_data[6];
                op_ref_price  <= ref_rd_data[62:31];
                op_ref_shares <= ref_rd_data[30:7];

                // Collision: entry valid but order_ref tag mismatch
                if (ref_rd_data[127] && (ref_rd_data[126:63] != op_order_ref)) begin
                    collision_flag  <= 1'b1;
                    collision_count <= collision_count + 32'h1;
                    state           <= S_DONE;
                // Not found (for modify ops): drop silently
                end else if (!ref_rd_data[127]) begin
                    state <= S_DONE;
                end else begin
                    state <= S_SCAN_BOOK;
                end
            end

            // ------------------------------------------------------------------
            S_SCAN_BOOK: begin
                // Load all 16 levels for this symbol/side and find target level
                // For Add ops: side = op_side; find first empty level (shares == 0)
                // For Modify ops: side = op_ref_side; find level where price matches op_ref_price
                begin
                    automatic logic        is_add;
                    automatic logic        found;
                    automatic logic [3:0]  lvl;
                    automatic logic [55:0] entry;

                    is_add = (op_msg_type == 8'h41) || (op_msg_type == 8'h46);
                    found  = 1'b0;
                    lvl    = 4'h0;

                    for (int k = 0; k < OB_LEVELS; k++) begin
                        automatic logic op_book_side;
                        op_book_side = is_add ? op_side : op_ref_side;
                        entry = book_mem[op_sym_id][op_book_side][k];
                        if (!found) begin
                            if (is_add) begin
                                // First empty slot (shares field [23:0] == 0)
                                if (entry[23:0] == 24'h0) begin
                                    lvl   = k[3:0];
                                    found = 1'b1;
                                end
                            end else begin
                                // Price match in existing entry
                                if (entry[55:24] == op_ref_price) begin
                                    lvl   = k[3:0];
                                    found = 1'b1;
                                end
                            end
                        end
                    end

                    target_level <= lvl;
                    target_found <= found;
                end

                state <= S_UPDATE;
            end

            // ------------------------------------------------------------------
            S_UPDATE: begin
                case (op_msg_type)

                    // --- Add Order ('A' or 'F') ---
                    8'h41, 8'h46: begin
                        // Write ref entry
                        ref_mem[op_hash] <= {1'b1, op_order_ref,
                                             op_price, op_shares, op_side, 6'h0};
                        // Write book level (+ mirror top 4 levels to l2_cache)
                        if (target_found) begin
                            book_mem[op_sym_id][op_side][target_level] <=
                                {op_price, op_shares};
                            if (target_level < 4)
                                l2_cache[op_sym_id][op_side][target_level[1:0]] <=
                                    {op_price, op_shares};
                        end

                        // BBO update (Phase 1 simplified — better price wins)
                        if (op_side == 1'b1) begin // bid
                            if (op_price > bbo_bid_price_r[op_sym_id]) begin
                                bbo_bid_price_r[op_sym_id] <= op_price;
                                bbo_bid_size_r[op_sym_id]  <= op_shares;
                            end
                        end else begin // ask
                            if (bbo_ask_price_r[op_sym_id] == 32'h0 ||
                                op_price < bbo_ask_price_r[op_sym_id]) begin
                                bbo_ask_price_r[op_sym_id] <= op_price;
                                bbo_ask_size_r[op_sym_id]  <= op_shares;
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    // --- Order Cancel ('X') — partial share reduction ---
                    8'h58: begin
                        begin
                            automatic logic [23:0] new_sh;
                            new_sh = (op_ref_shares > op_shares) ?
                                     (op_ref_shares - op_shares) : 24'h0;

                            // Read-modify-write ref entry
                            ref_mem[op_hash] <= {1'b1, op_order_ref,
                                                 op_ref_price, new_sh,
                                                 op_ref_side, 6'h0};

                            // Update book level (+ mirror l2_cache)
                            if (target_found) begin
                                book_mem[op_sym_id][op_ref_side][target_level] <=
                                    {op_ref_price, new_sh};
                                if (target_level < 4)
                                    l2_cache[op_sym_id][op_ref_side][target_level[1:0]] <=
                                        {op_ref_price, new_sh};
                            end

                            // BBO update: if share count hit 0 at BBO price → reset
                            if (new_sh == 24'h0) begin
                                if (op_ref_side == 1'b1) begin
                                    if (op_ref_price == bbo_bid_price_r[op_sym_id]) begin
                                        bbo_bid_price_r[op_sym_id] <= 32'h0;
                                        bbo_bid_size_r[op_sym_id]  <= 24'h0;
                                    end
                                end else begin
                                    if (op_ref_price == bbo_ask_price_r[op_sym_id]) begin
                                        bbo_ask_price_r[op_sym_id] <= 32'h0;
                                        bbo_ask_size_r[op_sym_id]  <= 24'h0;
                                    end
                                end
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    // --- Order Delete ('D') ---
                    8'h44: begin
                        // Invalidate ref entry
                        ref_mem[op_hash] <= 128'h0;

                        // Zero book level (+ mirror l2_cache)
                        if (target_found) begin
                            book_mem[op_sym_id][op_ref_side][target_level] <= 56'h0;
                            if (target_level < 4)
                                l2_cache[op_sym_id][op_ref_side][target_level[1:0]] <= 56'h0;
                        end

                        // BBO update: clear BBO if this was at BBO price
                        if (op_ref_side == 1'b1) begin
                            if (op_ref_price == bbo_bid_price_r[op_sym_id]) begin
                                bbo_bid_price_r[op_sym_id] <= 32'h0;
                                bbo_bid_size_r[op_sym_id]  <= 24'h0;
                            end
                        end else begin
                            if (op_ref_price == bbo_ask_price_r[op_sym_id]) begin
                                bbo_ask_price_r[op_sym_id] <= 32'h0;
                                bbo_ask_size_r[op_sym_id]  <= 24'h0;
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    // --- Order Replace ('U') — delete old, insert new ---
                    8'h55: begin
                        // Delete old ref entry
                        ref_mem[op_hash] <= 128'h0;

                        // Zero old book level (+ mirror l2_cache)
                        if (target_found) begin
                            book_mem[op_sym_id][op_ref_side][target_level] <= 56'h0;
                            if (target_level < 4)
                                l2_cache[op_sym_id][op_ref_side][target_level[1:0]] <= 56'h0;
                        end

                        // Write new ref entry at new_order_ref hash
                        ref_mem[op_new_hash] <= {1'b1, op_new_order_ref,
                                                 op_price, op_shares,
                                                 op_side, 6'h0};

                        // Reuse target_level for new entry (just zeroed → first empty)
                        if (target_found) begin
                            book_mem[op_sym_id][op_side][target_level] <=
                                {op_price, op_shares};
                            if (target_level < 4)
                                l2_cache[op_sym_id][op_side][target_level[1:0]] <=
                                    {op_price, op_shares};
                        end

                        // BBO: clear old if it was at BBO price
                        if (op_ref_side == 1'b1) begin
                            if (op_ref_price == bbo_bid_price_r[op_sym_id]) begin
                                bbo_bid_price_r[op_sym_id] <= 32'h0;
                                bbo_bid_size_r[op_sym_id]  <= 24'h0;
                            end
                        end else begin
                            if (op_ref_price == bbo_ask_price_r[op_sym_id]) begin
                                bbo_ask_price_r[op_sym_id] <= 32'h0;
                                bbo_ask_size_r[op_sym_id]  <= 24'h0;
                            end
                        end
                        // BBO: apply add logic for new order
                        if (op_side == 1'b1) begin
                            if (op_price > bbo_bid_price_r[op_sym_id]) begin
                                bbo_bid_price_r[op_sym_id] <= op_price;
                                bbo_bid_size_r[op_sym_id]  <= op_shares;
                            end
                        end else begin
                            if (bbo_ask_price_r[op_sym_id] == 32'h0 ||
                                op_price < bbo_ask_price_r[op_sym_id]) begin
                                bbo_ask_price_r[op_sym_id] <= op_price;
                                bbo_ask_size_r[op_sym_id]  <= op_shares;
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    // --- Order Executed ('E' / 'C') — partial or full execution ---
                    8'h45, 8'h43: begin
                        begin
                            automatic logic [23:0] new_sh;
                            new_sh = (op_ref_shares > op_shares) ?
                                     (op_ref_shares - op_shares) : 24'h0;

                            if (new_sh == 24'h0) begin
                                // Fully executed — invalidate
                                ref_mem[op_hash] <= 128'h0;
                                if (target_found) begin
                                    book_mem[op_sym_id][op_ref_side][target_level] <= 56'h0;
                                    if (target_level < 4)
                                        l2_cache[op_sym_id][op_ref_side][target_level[1:0]] <= 56'h0;
                                end
                            end else begin
                                // Partial execution — update shares
                                ref_mem[op_hash] <= {1'b1, op_order_ref,
                                                     op_ref_price, new_sh,
                                                     op_ref_side, 6'h0};
                                if (target_found) begin
                                    book_mem[op_sym_id][op_ref_side][target_level] <=
                                        {op_ref_price, new_sh};
                                    if (target_level < 4)
                                        l2_cache[op_sym_id][op_ref_side][target_level[1:0]] <=
                                            {op_ref_price, new_sh};
                                end
                            end

                            // BBO: if fully exec'd and was at BBO price → reset
                            if (new_sh == 24'h0) begin
                                if (op_ref_side == 1'b1) begin
                                    if (op_ref_price == bbo_bid_price_r[op_sym_id]) begin
                                        bbo_bid_price_r[op_sym_id] <= 32'h0;
                                        bbo_bid_size_r[op_sym_id]  <= 24'h0;
                                    end
                                end else begin
                                    if (op_ref_price == bbo_ask_price_r[op_sym_id]) begin
                                        bbo_ask_price_r[op_sym_id] <= 32'h0;
                                        bbo_ask_size_r[op_sym_id]  <= 24'h0;
                                    end
                                end
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    default: begin
                        // Should not reach — handled in S_IDLE routing
                    end
                endcase

                state <= S_DONE;
            end

            // ------------------------------------------------------------------
            S_DONE: begin
                state <= S_IDLE;
            end

            default: state <= S_IDLE;

        endcase
    end
end

endmodule

`default_nettype wire
