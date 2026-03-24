// arith_edge_seq.sv — Arithmetic edge-case sequence for bfloat16_mul + fp32_acc
//
// Targets uncovered lines:
//   bfloat16_mul.sv — norm_shift path, exponent underflow/overflow
//   fp32_acc.sv     — sum_man==0, deep renormalization chain (bits [16]–[1])
//
// Strategy: craft specific bfloat16 weight/feature values that produce
// products triggering these paths.  Send through the full pipeline
// (ITCH → features → dot-product) by choosing prices that yield the
// correct bfloat16 feature magnitudes.

class arith_edge_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(arith_edge_seq)

    longint unsigned m_next_order_ref;

    function new(string name = "arith_edge_seq");
        super.new(name);
        m_next_order_ref = 64'hAAAA_0000_0000_0001;
    endfunction

    task body();
        `uvm_info("ARITH_EDGE", "Starting arithmetic edge-case sequence", UVM_LOW)

        // ---- 1. Zero price → features include 0.0 → bfloat16(0)*w = 0
        //         Exercises a_zero/b_zero branch in bfloat16_mul
        send_add_order(m_next_order_ref++, 1, 0, 100);

        // ---- 2. Very small price (1 CPM) → tiny bfloat16 features
        //         With right weights, product mantissa won't have bit[15]
        //         → exercises non-norm_shift path
        send_add_order(m_next_order_ref++, 0, 1, 100);

        // ---- 3. Large price → big bfloat16 features
        //         Product can overflow exponent (exp_sum > 255)
        //         → exercises r_exp_wide[8] overflow clamp (line 89)
        send_add_order(m_next_order_ref++, 1, 999999, 100);

        // ---- 4. Moderate price → exercises norm_shift=1 path
        //         man_product[15]=1 → shift right, increment exp
        //         → exercises lines 69-70
        send_add_order(m_next_order_ref++, 0, 15000, 100);

        // ---- 5. Price 2 CPM → very tiny features
        //         May produce subnormal intermediate → exp underflow
        //         → exercises r_exp_wide[9] underflow (line 84, 86)
        send_add_order(m_next_order_ref++, 1, 2, 100);

        // ---- 6. Buy at price = 100 (moderate, different feature encoding)
        //         First accumulation: big + tiny → near-cancellation
        //         → exercises deep renormalization chain in fp32_acc
        send_add_order(m_next_order_ref++, 1, 100, 100);

        // ---- 7. Sell at price = 3 (another tiny value)
        //         Accumulator with near-zero partial sums
        //         → exercises sum_man==0 branch (lines 112–113)
        send_add_order(m_next_order_ref++, 0, 3, 100);

        // ---- 8. Price that generates subnormal bfloat16 features
        //         bfloat16 subnormal: exponent=0, mantissa≠0
        //         → product of subnormal × normal = small exp
        //         → exercises r_exp_wide[9] (underflow) fully
        send_add_order(m_next_order_ref++, 1, 5, 100);

        // ---- 9. Alternating buy/sell to trigger sign differences in acc
        //         Subtraction of nearly-equal magnitudes → deep renorm
        send_add_order(m_next_order_ref++, 1, 10000, 100);
        send_add_order(m_next_order_ref++, 0, 10001, 100);

        // ---- 10. Max 32-bit price → extreme values
        send_add_order(m_next_order_ref++, 1, 32'h7FFF_FFFF, 100);

        `uvm_info("ARITH_EDGE", "Arithmetic edge-case sequence complete", UVM_LOW)
    endtask

    // Construct and send a single ITCH Add Order message
    task send_add_order(longint unsigned order_ref, bit side,
                        int unsigned price, int unsigned shares);
        byte unsigned msg[36];
        byte unsigned framed[];

        // Build Add Order body (36 bytes)
        msg[0] = 8'h41;  // 'A' = Add Order
        // stock_locate (2B), tracking_number (2B), timestamp (6B) = 0
        for (int i = 1; i < 11; i++) msg[i] = 0;
        // order_reference_number (8 bytes, big-endian)
        for (int i = 0; i < 8; i++)
            msg[11 + i] = (order_ref >> (56 - i*8)) & 8'hFF;
        // buy_sell_indicator
        msg[19] = side ? 8'h42 : 8'h53;
        // shares (4 bytes, big-endian)
        msg[20] = (shares >> 24) & 8'hFF;
        msg[21] = (shares >> 16) & 8'hFF;
        msg[22] = (shares >>  8) & 8'hFF;
        msg[23] =  shares        & 8'hFF;
        // stock (8 bytes)
        msg[24] = "T"; msg[25] = "E"; msg[26] = "S"; msg[27] = "T";
        msg[28] = " "; msg[29] = " "; msg[30] = " "; msg[31] = " ";
        // price (4 bytes, big-endian)
        msg[32] = (price >> 24) & 8'hFF;
        msg[33] = (price >> 16) & 8'hFF;
        msg[34] = (price >>  8) & 8'hFF;
        msg[35] =  price        & 8'hFF;

        // Frame with 2-byte big-endian length prefix
        framed = new[38];
        framed[0] = (36 >> 8) & 8'hFF;
        framed[1] =  36       & 8'hFF;
        for (int i = 0; i < 36; i++)
            framed[2 + i] = msg[i];

        send_framed_message(framed);
        `uvm_info("ARITH_EDGE", $sformatf("Sent order ref=0x%016h side=%0b price=%0d",
                  order_ref, side, price), UVM_MEDIUM)
    endtask

    task send_framed_message(byte unsigned framed[]);
        axi4_stream_transaction tx;
        int num_beats, byte_idx;

        num_beats = (framed.size() + 7) / 8;
        tx = axi4_stream_transaction::type_id::create("tx");
        tx.tdata = new[num_beats];

        byte_idx = 0;
        for (int beat = 0; beat < num_beats; beat++) begin
            tx.tdata[beat] = '0;
            for (int b = 0; b < 8 && byte_idx < framed.size(); b++) begin
                tx.tdata[beat][63 - b*8 -: 8] = framed[byte_idx];
                byte_idx++;
            end
        end

        start_item(tx);
        finish_item(tx);
    endtask
endclass
