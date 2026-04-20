// order_book.sv — BRAM-backed L3 order book for LLIU v2.0 Phase 1
//
// Resources (xc7k160tffg676-2 estimates):
//   book_mem : 4 levels × 128 entries × 56b ≈ 448 LUTs (LUTRAM)
//   ref_mem  : 8K × 128b ≈ 57 BRAM18   (inference)
//   bbo_*_r  : 64 × 4 × 32b + 2 × 24b = FF arrays
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
    input  logic [OB_SYM_ID_W-1:0] sym_id,  // 0..OB_NUM_SYMBOLS-1
    input  logic        fields_valid,
    // BBO combinatorial query (1-cycle FF latency)
    input  logic [OB_SYM_ID_W-1:0] bbo_query_sym,
    output logic [31:0] bbo_bid_price,
    output logic [31:0] bbo_ask_price,
    output logic [23:0] bbo_bid_size,
    output logic [23:0] bbo_ask_size,
    // BBO update notification (1-cycle pulse)
    output logic        bbo_valid,
    output logic [OB_SYM_ID_W-1:0] bbo_sym_id,
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
// book_mem: OB_LEVELS levels × (OB_NUM_SYMBOLS × 2 sides) entries × 56 bits
// Entry: {price[31:0], shares[23:0]} = 56 bits
// Restructured from 3D to 2D: Vivado infers OB_LEVELS separate LUTRAMs.
// S_SCAN_BOOK reads one entry per level per cycle across all LUTRAMs
// simultaneously — 1 read port per LUTRAM, no multi-port conflicts.
// 4 × 128 × 56b = 28 Kbits ≈ 448 LUTs (distributed RAM).
/* verilator lint_off UNOPTFLAT */
(* ram_style = "distributed" *) logic [55:0] book_mem [0:OB_LEVELS-1][0:(OB_NUM_SYMBOLS*2-1)];

// ref_mem: 2^OB_REF_TABLE_BITS = 8192 entries, 128 bits wide
// Layout: [127]=valid, [126:63]=order_ref(64b), [62:31]=price(32b), [30:7]=shares(24b),
//         [6]=side, [5:0]=reserved
(* ram_style = "block" *) logic [127:0] ref_mem [0:(1<<OB_REF_TABLE_BITS)-1];
/* verilator lint_on UNOPTFLAT */

// l2_cache: shadow of book_mem levels 0-3 per side per symbol.
// With OB_LEVELS=4, l2_cache mirrors book_mem exactly — kept for interface
// consistency with the L2 query path.
// 4 × 128 × 56b = 28 Kbits ≈ 448 LUTs (distributed RAM).
logic [55:0] l2_cache [0:3][0:(OB_NUM_SYMBOLS*2-1)];

// BBO registers — kept as flip-flops for single-cycle registered read
logic [31:0] bbo_bid_price_r [0:OB_NUM_SYMBOLS-1];
logic [31:0] bbo_ask_price_r [0:OB_NUM_SYMBOLS-1];
logic [23:0] bbo_bid_size_r  [0:OB_NUM_SYMBOLS-1];
logic [23:0] bbo_ask_size_r  [0:OB_NUM_SYMBOLS-1];

// ---------------------------------------------------------------------------
// FSM state
// ---------------------------------------------------------------------------
typedef enum logic [3:0] {
    S_IDLE      = 4'd0,
    S_READ_REF1 = 4'd1,
    S_READ_REF2 = 4'd2,
    S_PROCESS   = 4'd3,
    S_SCAN_BOOK = 4'd4,
    S_UPDATE    = 4'd5,
    S_DONE      = 4'd6,
    S_UPDATE2   = 4'd7,  // Replace only: second write to invalidate old hash slot
    S_MATCH      = 4'd8,  // Register comparison results before S_SCAN_BOOK (breaks BRAM→CE timing path)
    S_SCAN_BOOK2 = 4'd9,  // Compare book_entry_r → match_vec (breaks MUX→compare timing path)
    S_SCAN_BOOK3 = 4'd10  // Priority encode match_vec → target_level + BBO pre-registers
} ob_state_t;

ob_state_t state;

// ---------------------------------------------------------------------------
// Linear-probe parameters
// ---------------------------------------------------------------------------
localparam int OB_MAX_PROBE = 4;  // up to 4 extra slots probed on collision

// ---------------------------------------------------------------------------
// Operation registers (latched in S_IDLE on fields_valid)
// ---------------------------------------------------------------------------
logic [7:0]  op_msg_type;
logic [63:0] op_order_ref;
logic [63:0] op_new_order_ref;
logic [31:0] op_price;
logic [23:0] op_shares;          // truncated to 24 bits
logic        op_side;
logic [OB_SYM_ID_W-1:0] op_sym_id;
/* verilator lint_off UNUSEDSIGNAL */
logic [16:0] op_hash;
logic [16:0] op_new_hash;        // CRC of new_order_ref (for Replace)
/* verilator lint_on UNUSEDSIGNAL */
logic [2:0]  probe_cnt;          // 0..OB_MAX_PROBE linear-probe step counter
// Resolved slot address (base hash + probe_cnt, truncated to table width)
// Used to write to the correct probed slot rather than always the base hash.
logic [OB_REF_TABLE_BITS-1:0] op_resolved_addr;

/* verilator lint_off UNUSEDSIGNAL */
logic [127:0] ref_rd_data;       // BRAM read pipeline register; [5:0] are reserved
/* verilator lint_on UNUSEDSIGNAL */
logic [OB_REF_TABLE_BITS-1:0] ref_rd_addr;       // registered address for BRAM read

// Single registered write port — Vivado BRAM inference requirement
logic                         ref_wr_en;
logic [OB_REF_TABLE_BITS-1:0] ref_wr_addr;
logic [127:0]                 ref_wr_data;

// Scan-phase state
localparam int OB_LVL_W = $clog2(OB_LEVELS);
logic [OB_LVL_W-1:0] target_level;
logic         target_found;
logic [31:0]  op_ref_price;      // from ref entry
/* verilator lint_off UNUSEDSIGNAL */
logic [23:0]  op_ref_shares;     // from ref entry
/* verilator lint_on UNUSEDSIGNAL */
logic         op_ref_side;       // from ref entry
// Pre-registered in S_PROCESS to break the fo=256 fan-out path in S_SCAN_BOOK
logic         is_add_r;          // (op_msg_type=='A'||'F'), registered one cycle before S_SCAN_BOOK
logic         op_book_side_r;    // is_add ? op_side : op_ref_side, registered one cycle before S_SCAN_BOOK
// S_MATCH pipeline registers — break the BRAM-output→comparator→register-CE timing path
logic         is_add_op_r;       // pre-registered in S_IDLE: op_msg_type is Add
logic         ref_match_r;       // registered in S_PROCESS: ref_rd_data[127] && order_ref match
logic         ref_empty_r;       // registered in S_PROCESS: !ref_rd_data[127]
logic [OB_LEVELS-1:0] match_vec; // per-level match flags registered in S_SCAN_BOOK2
logic [55:0] book_entry_r [0:OB_LEVELS-1]; // registered book_mem read data (Run 57: breaks MUX→compare timing path)
logic [23:0] new_sh_r;      // pre-registered in S_PROCESS: max(op_ref_shares-op_shares, 0)
logic        new_sh_zero_r; // pre-registered in S_PROCESS: new_sh would be zero (fully consumed)
// BBO comparison pre-registers — breaks 64-entry mux + 32-bit compare out of S_UPDATE
logic [31:0] bbo_bid_price_snap_r; // registered in S_SCAN_BOOK: bbo_bid_price_r[op_sym_id]
logic [31:0] bbo_ask_price_snap_r; // registered in S_SCAN_BOOK: bbo_ask_price_r[op_sym_id]
/* verilator lint_off UNUSEDSIGNAL */
logic [23:0] bbo_bid_size_snap_r;  // registered in S_SCAN_BOOK: bbo_bid_size_r[op_sym_id]
logic [23:0] bbo_ask_size_snap_r;  // registered in S_SCAN_BOOK: bbo_ask_size_r[op_sym_id]
/* verilator lint_on UNUSEDSIGNAL */
logic        bbo_bid_better_r;     // registered in S_SCAN_BOOK2: op_price > bbo_bid_price_snap_r
logic        bbo_ask_better_r;     // registered in S_SCAN_BOOK2: bbo_ask==0 || op_price < bbo_ask_price_snap_r
logic        bbo_ref_eq_bid_r;     // registered in S_SCAN_BOOK2: op_ref_price == bbo_bid_price_snap_r
logic        bbo_ref_eq_ask_r;     // registered in S_SCAN_BOOK2: op_ref_price == bbo_ask_price_snap_r

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
        l2_bid_price[k] <= l2_cache[k][{bbo_query_sym, 1'b1}][55:24];
        l2_bid_size[k]  <= l2_cache[k][{bbo_query_sym, 1'b1}][23:0];
        l2_ask_price[k] <= l2_cache[k][{bbo_query_sym, 1'b0}][55:24];
        l2_ask_size[k]  <= l2_cache[k][{bbo_query_sym, 1'b0}][23:0];
    end
end

// ---------------------------------------------------------------------------
// ref_mem single-port write
// All FSM write sites drive ref_wr_en/addr/data; this block is the sole writer.
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (ref_wr_en)
        ref_mem[ref_wr_addr] <= ref_wr_data;
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
        bbo_sym_id      <= '0;
        op_msg_type     <= 8'h0;
        op_order_ref    <= 64'h0;
        op_new_order_ref<= 64'h0;
        op_price        <= 32'h0;
        op_shares       <= 24'h0;
        op_side         <= 1'b0;
        op_sym_id       <= '0;
        op_hash         <= 17'h0;
        op_new_hash     <= 17'h0;
        probe_cnt       <= 3'd0;
        op_resolved_addr<= '0;
        ref_rd_data     <= 128'h0;
        ref_rd_addr     <= '0;
        ref_wr_en       <= 1'b0;
        ref_wr_addr     <= '0;
        ref_wr_data     <= 128'h0;
        target_level    <= '0;
        target_found    <= 1'b0;
        op_ref_price    <= 32'h0;
        op_ref_shares   <= 24'h0;
        op_ref_side     <= 1'b0;
        is_add_r        <= 1'b0;
        op_book_side_r  <= 1'b0;
        is_add_op_r     <= 1'b0;
        ref_match_r     <= 1'b0;
        ref_empty_r     <= 1'b0;
        match_vec       <= '0;
        for (int k = 0; k < OB_LEVELS; k++) book_entry_r[k] <= 56'h0;
        new_sh_r        <= 24'h0;
        new_sh_zero_r   <= 1'b0;
        bbo_bid_price_snap_r <= 32'h0;
        bbo_ask_price_snap_r <= 32'h0;
        bbo_bid_size_snap_r  <= 24'h0;
        bbo_ask_size_snap_r  <= 24'h0;
        bbo_bid_better_r     <= 1'b0;
        bbo_ask_better_r     <= 1'b0;
        bbo_ref_eq_bid_r     <= 1'b0;
        bbo_ref_eq_ask_r     <= 1'b0;
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
        ref_wr_en      <= 1'b0;

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
                    probe_cnt        <= 3'd0;
                    is_add_op_r      <= (msg_type == 8'h41) || (msg_type == 8'h46);

                    // Route based on message type
                    case (msg_type)
                        8'h41, // 'A' Add Order
                        8'h46: // 'F' Add Order (MPID)
                            // Use S_READ_REF1 to probe for an empty slot (linear probing)
                            state <= S_READ_REF1;

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
            // 2-cycle BRAM read pipeline (linear probe: address = hash + probe_cnt)
            // ------------------------------------------------------------------
            S_READ_REF1: begin
                ref_rd_addr <= OB_REF_TABLE_BITS'(op_hash + {14'h0, probe_cnt});
                state       <= S_READ_REF2;
            end

            S_READ_REF2: begin
                ref_rd_data <= ref_mem[ref_rd_addr];
                state       <= S_PROCESS;
            end

            // ------------------------------------------------------------------
            S_PROCESS: begin
                // Register all BRAM-derived comparison results so S_MATCH uses
                // only FDREs, breaking the BRAM-output→64b-comparator→register-CE
                // timing path that caused WNS = -1.921 ns.
                ref_match_r    <= ref_rd_data[127] && (ref_rd_data[126:63] == op_order_ref);
                ref_empty_r    <= !ref_rd_data[127];
                // Unconditionally latch ref fields (only used on modify path)
                op_ref_side   <= ref_rd_data[6];
                op_ref_price  <= ref_rd_data[62:31];
                op_ref_shares <= ref_rd_data[30:7];
                // Pre-latch resolved address (only used when match succeeds)
                op_resolved_addr <= ref_rd_addr;
                // Pre-register new_sh for Cancel/Execute paths (breaks 24-bit CARRY chain in S_UPDATE)
                new_sh_r      <= (ref_rd_data[30:7] > op_shares) ?
                                 (ref_rd_data[30:7] - op_shares) : 24'h0;
                new_sh_zero_r <= !(ref_rd_data[30:7] > op_shares);
                state <= S_MATCH;
            end

            // ------------------------------------------------------------------
            // S_MATCH: all inputs are FDREs (no BRAM combinational dependency).
            // Decides proceed-to-S_SCAN_BOOK vs. probe-next-slot vs. drop.
            // ------------------------------------------------------------------
            S_MATCH: begin
                if (is_add_op_r) begin
                    // Add: accept slot if empty OR same order_ref (duplicate overwrite)
                    if (ref_empty_r || ref_match_r) begin
                        is_add_r       <= 1'b1;
                        op_book_side_r <= op_side;
                        state          <= S_SCAN_BOOK;
                    end else begin
                        // Slot occupied by different order — probe next slot
                        if (probe_cnt == 3'(OB_MAX_PROBE)) begin
                            collision_flag  <= 1'b1;
                            collision_count <= collision_count + 32'h1;
                            state           <= S_DONE;
                        end else begin
                            probe_cnt <= probe_cnt + 3'd1;
                            state     <= S_READ_REF1;
                        end
                    end
                end else begin
                    // Modify/Delete/Execute/Replace
                    if (ref_empty_r) begin
                        // Slot empty — order not in table, drop silently
                        state <= S_DONE;
                    end else if (ref_match_r) begin
                        // Exact match — proceed with registered side from op_ref_side
                        is_add_r       <= 1'b0;
                        op_book_side_r <= op_ref_side; // registered in S_PROCESS, FDRE
                        state          <= S_SCAN_BOOK;
                    end else begin
                        // Collision: valid entry for different order_ref
                        collision_flag  <= 1'b1;
                        collision_count <= collision_count + 32'h1;
                        if (probe_cnt == 3'(OB_MAX_PROBE)) begin
                            state <= S_DONE;
                        end else begin
                            probe_cnt <= probe_cnt + 3'd1;
                            state     <= S_READ_REF1;
                        end
                    end
                end
            end

            // ------------------------------------------------------------------
            S_SCAN_BOOK: begin
                // Stage 1: read book_mem entries into registers (MUX tree only, no compare).
                // Breaking the FDRE→128:1-MUX→32b-compare→match_vec path (Run 57).
                for (int k = 0; k < OB_LEVELS; k++) begin
                    book_entry_r[k] <= book_mem[k][{op_sym_id, op_book_side_r}];
                end
                // BBO price/size snapshot — breaks 64-entry mux decode out of S_UPDATE
                bbo_bid_price_snap_r <= bbo_bid_price_r[op_sym_id];
                bbo_ask_price_snap_r <= bbo_ask_price_r[op_sym_id];
                bbo_bid_size_snap_r  <= bbo_bid_size_r[op_sym_id];
                bbo_ask_size_snap_r  <= bbo_ask_size_r[op_sym_id];
                state <= S_SCAN_BOOK2;
            end

            // ------------------------------------------------------------------
            S_SCAN_BOOK2: begin
                // Stage 2: compare registered book_mem entries → match_vec.
                // All inputs are FDREs; path depth ~4 LUTs (CARRY4 equality only).
                for (int k = 0; k < OB_LEVELS; k++) begin
                    if (is_add_r)
                        match_vec[k] <= (book_entry_r[k][23:0] == 24'h0);
                    else
                        match_vec[k] <= (book_entry_r[k][55:24] == op_ref_price);
                end
                state <= S_SCAN_BOOK3;
            end

            // ------------------------------------------------------------------
            S_SCAN_BOOK3: begin
                // Stage 3: priority encode match_vec → target_level, target_found.
                // All inputs are FDREs; max path depth ~3 LUTs for OB_LEVELS=4.
                begin
                    automatic logic                found;
                    automatic logic [OB_LVL_W-1:0] lvl;
                    found = 1'b0;
                    lvl   = '0;
                    for (int k = 0; k < OB_LEVELS; k++) begin
                        if (!found && match_vec[k]) begin
                            lvl   = OB_LVL_W'(k);
                            found = 1'b1;
                        end
                    end
                    target_level <= lvl;
                    target_found <= found;
                end
                // BBO comparison pre-registers
                bbo_bid_better_r <= (op_price > bbo_bid_price_snap_r);
                bbo_ask_better_r <= (bbo_ask_price_snap_r == 32'h0 ||
                                     op_price < bbo_ask_price_snap_r);
                bbo_ref_eq_bid_r <= (op_ref_price == bbo_bid_price_snap_r);
                bbo_ref_eq_ask_r <= (op_ref_price == bbo_ask_price_snap_r);
                state <= S_UPDATE;
            end

            // ------------------------------------------------------------------
            S_UPDATE: begin
                case (op_msg_type)

                    // --- Add Order ('A' or 'F') ---
                    8'h41, 8'h46: begin
                        // Write ref entry to the resolved (probed) slot
                        ref_wr_en   <= 1'b1;
                        ref_wr_addr <= op_resolved_addr;
                        ref_wr_data <= {1'b1, op_order_ref,
                                        op_price, op_shares, op_side, 6'h0};
                        // Write book level (+ mirror top 4 levels to l2_cache)
                        if (target_found) begin
                            book_mem[target_level][{op_sym_id, op_side}] <=
                                {op_price, op_shares};
                            l2_cache[target_level][{op_sym_id, op_side}] <=
                                    {op_price, op_shares};
                        end

                        // BBO update (Phase 1 simplified — better price wins)
                        if (op_side == 1'b1) begin // bid
                            if (bbo_bid_better_r) begin
                                bbo_bid_price_r[op_sym_id] <= op_price;
                                bbo_bid_size_r[op_sym_id]  <= op_shares;
                            end
                        end else begin // ask
                            if (bbo_ask_better_r) begin
                                bbo_ask_price_r[op_sym_id] <= op_price;
                                bbo_ask_size_r[op_sym_id]  <= op_shares;
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    // --- Order Cancel ('X') — partial share reduction ---
                    // new_sh_r / new_sh_zero_r pre-registered in S_PROCESS (breaks CARRY-chain timing path)
                    8'h58: begin
                        // Write ref entry to the resolved (probed) slot
                        ref_wr_en   <= 1'b1;
                        ref_wr_addr <= op_resolved_addr;
                        ref_wr_data <= {1'b1, op_order_ref,
                                        op_ref_price, new_sh_r,
                                        op_ref_side, 6'h0};

                        // Update book level (+ mirror l2_cache)
                        if (target_found) begin
                            book_mem[target_level][{op_sym_id, op_ref_side}] <=
                                {op_ref_price, new_sh_r};
                            l2_cache[target_level][{op_sym_id, op_ref_side}] <=
                                    {op_ref_price, new_sh_r};
                        end

                        // BBO update: if share count hit 0 at BBO price → reset
                        if (new_sh_zero_r) begin
                            if (op_ref_side == 1'b1) begin
                                if (bbo_ref_eq_bid_r) begin
                                    bbo_bid_price_r[op_sym_id] <= 32'h0;
                                    bbo_bid_size_r[op_sym_id]  <= 24'h0;
                                end
                            end else begin
                                if (bbo_ref_eq_ask_r) begin
                                    bbo_ask_price_r[op_sym_id] <= 32'h0;
                                    bbo_ask_size_r[op_sym_id]  <= 24'h0;
                                end
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    // --- Order Delete ('D') ---
                    8'h44: begin
                        // Invalidate the resolved (probed) slot
                        ref_wr_en   <= 1'b1;
                        ref_wr_addr <= op_resolved_addr;
                        ref_wr_data <= 128'h0;

                        // Zero book level (+ mirror l2_cache)
                        if (target_found) begin
                            book_mem[target_level][{op_sym_id, op_ref_side}] <= 56'h0;
                            l2_cache[target_level][{op_sym_id, op_ref_side}] <= 56'h0;
                        end

                        // BBO update: clear BBO if this was at BBO price
                        if (op_ref_side == 1'b1) begin
                            if (bbo_ref_eq_bid_r) begin
                                bbo_bid_price_r[op_sym_id] <= 32'h0;
                                bbo_bid_size_r[op_sym_id]  <= 24'h0;
                            end
                        end else begin
                            if (bbo_ref_eq_ask_r) begin
                                bbo_ask_price_r[op_sym_id] <= 32'h0;
                                bbo_ask_size_r[op_sym_id]  <= 24'h0;
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    // --- Order Replace ('U') — delete old, insert new ---
                    8'h55: begin
                        // Delete old ref entry deferred to S_UPDATE2 (single write port)

                        // Zero old book level (+ mirror l2_cache)
                        if (target_found) begin
                            book_mem[target_level][{op_sym_id, op_ref_side}] <= 56'h0;
                            l2_cache[target_level][{op_sym_id, op_ref_side}] <= 56'h0;
                        end

                        // Write new ref entry via registered write port
                        ref_wr_en   <= 1'b1;
                        ref_wr_addr <= op_new_hash[OB_REF_TABLE_BITS-1:0];
                        ref_wr_data <= {1'b1, op_new_order_ref,
                                        op_price, op_shares, op_side, 6'h0};

                        // Reuse target_level for new entry (just zeroed → first empty)
                        if (target_found) begin
                            book_mem[target_level][{op_sym_id, op_side}] <=
                                {op_price, op_shares};
                            l2_cache[target_level][{op_sym_id, op_side}] <=
                                    {op_price, op_shares};
                        end

                        // BBO: clear old if it was at BBO price
                        if (op_ref_side == 1'b1) begin
                            if (bbo_ref_eq_bid_r) begin
                                bbo_bid_price_r[op_sym_id] <= 32'h0;
                                bbo_bid_size_r[op_sym_id]  <= 24'h0;
                            end
                        end else begin
                            if (bbo_ref_eq_ask_r) begin
                                bbo_ask_price_r[op_sym_id] <= 32'h0;
                                bbo_ask_size_r[op_sym_id]  <= 24'h0;
                            end
                        end
                        // BBO: apply add logic for new order
                        if (op_side == 1'b1) begin
                            if (bbo_bid_better_r) begin
                                bbo_bid_price_r[op_sym_id] <= op_price;
                                bbo_bid_size_r[op_sym_id]  <= op_shares;
                            end
                        end else begin
                            if (bbo_ask_better_r) begin
                                bbo_ask_price_r[op_sym_id] <= op_price;
                                bbo_ask_size_r[op_sym_id]  <= op_shares;
                            end
                        end

                        bbo_valid  <= 1'b1;
                        bbo_sym_id <= op_sym_id;
                    end

                    // --- Order Executed ('E' / 'C') — partial or full execution ---
                    // new_sh_r / new_sh_zero_r pre-registered in S_PROCESS (breaks CARRY-chain timing path)
                    8'h45, 8'h43: begin
                        // Write ref entry to the resolved (probed) slot
                        ref_wr_en   <= 1'b1;
                        ref_wr_addr <= op_resolved_addr;

                        if (new_sh_zero_r) begin
                            // Fully executed — invalidate
                            ref_wr_data <= 128'h0;
                            if (target_found) begin
                                book_mem[target_level][{op_sym_id, op_ref_side}] <= 56'h0;
                                l2_cache[target_level][{op_sym_id, op_ref_side}] <= 56'h0;
                            end
                        end else begin
                            // Partial execution — update shares
                            ref_wr_data <= {1'b1, op_order_ref,
                                            op_ref_price, new_sh_r,
                                            op_ref_side, 6'h0};
                            if (target_found) begin
                                book_mem[target_level][{op_sym_id, op_ref_side}] <=
                                    {op_ref_price, new_sh_r};
                                l2_cache[target_level][{op_sym_id, op_ref_side}] <=
                                        {op_ref_price, new_sh_r};
                            end
                        end

                        // BBO: if fully exec'd and was at BBO price → reset
                        if (new_sh_zero_r) begin
                            if (op_ref_side == 1'b1) begin
                                if (bbo_ref_eq_bid_r) begin
                                    bbo_bid_price_r[op_sym_id] <= 32'h0;
                                    bbo_bid_size_r[op_sym_id]  <= 24'h0;
                                end
                            end else begin
                                if (bbo_ref_eq_ask_r) begin
                                    bbo_ask_price_r[op_sym_id] <= 32'h0;
                                    bbo_ask_size_r[op_sym_id]  <= 24'h0;
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

                // Replace needs a second write cycle to clear the old hash slot
                state <= (op_msg_type == 8'h55) ? S_UPDATE2 : S_DONE;
            end

            // ------------------------------------------------------------------
            // S_UPDATE2: Replace only — invalidate old order-ref hash slot
            // (uses op_resolved_addr which holds the probed slot for old order_ref)
            // ------------------------------------------------------------------
            S_UPDATE2: begin
                ref_wr_en   <= 1'b1;
                ref_wr_addr <= op_resolved_addr;
                ref_wr_data <= 128'h0;
                state       <= S_DONE;
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
