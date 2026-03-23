// itch_random_seq.sv — Constrained-random ITCH Add Order sequence
//
// Generates random valid Add Order messages with configurable constraints:
//   - Price range: penny (1-99), dollar (100-9999), large (10000+)
//   - Side: 50/50 buy/sell
//   - Order ref: unique incrementing

class itch_random_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(itch_random_seq)

    // Number of random messages to generate
    rand int unsigned num_messages;
    constraint c_num_messages { num_messages inside {[10:1000]}; }

    // Price constraints
    rand int unsigned min_price;
    rand int unsigned max_price;
    constraint c_price_range {
        min_price >= 1;
        max_price <= 999999;
        max_price >= min_price;
    }

    // Internal state
    longint unsigned m_next_order_ref;

    // Randomizable order fields (declared before use)
    rand int unsigned m_rand_price;
    rand bit          m_rand_side;
    rand int unsigned m_rand_shares;
    constraint c_shares { m_rand_shares inside {[1:10000]}; }
    constraint c_side   { m_rand_side dist {1 := 50, 0 := 50}; }

    function new(string name = "itch_random_seq");
        super.new(name);
        num_messages = 100;
        min_price = 1;
        max_price = 999999;
        m_next_order_ref = 64'h0000_0001_0000_0000;
    endfunction

    task body();
        `uvm_info("RANDOM_SEQ", $sformatf("Generating %0d random Add Orders (price %0d-%0d)",
                  num_messages, min_price, max_price), UVM_LOW)

        for (int i = 0; i < num_messages; i++) begin
            if (!this.randomize(m_rand_price, m_rand_side, m_rand_shares) with {
                m_rand_price >= min_price;
                m_rand_price <= max_price;
            }) begin
                `uvm_error("RANDOM_SEQ", "Randomization failed")
                return;
            end

            send_add_order(m_next_order_ref, m_rand_side, m_rand_price, m_rand_shares);
            m_next_order_ref++;
        end

        `uvm_info("RANDOM_SEQ", $sformatf("Sent %0d random Add Orders", num_messages), UVM_LOW)
    endtask

    // Build and send a single ITCH Add Order
    task send_add_order(longint unsigned order_ref, bit side, int unsigned price, int unsigned shares);
        byte unsigned msg[36];
        byte unsigned framed[];
        axi4_stream_transaction tx;
        int num_beats, byte_idx;

        // Message type = Add Order
        msg[0] = 8'h41;

        // stock_locate, tracking_number, timestamp = 0
        for (int i = 1; i < 11; i++) msg[i] = 0;

        // order_reference (8 bytes, big-endian)
        for (int i = 0; i < 8; i++)
            msg[11 + i] = (order_ref >> (56 - i*8)) & 8'hFF;

        // side
        msg[19] = side ? 8'h42 : 8'h53;

        // shares (4 bytes, big-endian)
        msg[20] = (shares >> 24) & 8'hFF;
        msg[21] = (shares >> 16) & 8'hFF;
        msg[22] = (shares >>  8) & 8'hFF;
        msg[23] =  shares        & 8'hFF;

        // stock = "TEST    "
        msg[24] = "T"; msg[25] = "E"; msg[26] = "S"; msg[27] = "T";
        msg[28] = " "; msg[29] = " "; msg[30] = " "; msg[31] = " ";

        // price (4 bytes, big-endian)
        msg[32] = (price >> 24) & 8'hFF;
        msg[33] = (price >> 16) & 8'hFF;
        msg[34] = (price >>  8) & 8'hFF;
        msg[35] =  price        & 8'hFF;

        // Frame with 2-byte length prefix
        framed = new[38];
        framed[0] = 8'h00;
        framed[1] = 8'h24;  // 36 decimal
        for (int i = 0; i < 36; i++)
            framed[2 + i] = msg[i];

        // Pack into AXI4-Stream transaction
        num_beats = (38 + 7) / 8;
        tx = axi4_stream_transaction::type_id::create("tx");
        tx.tdata = new[num_beats];

        byte_idx = 0;
        for (int beat = 0; beat < num_beats; beat++) begin
            tx.tdata[beat] = '0;
            for (int b = 0; b < 8 && byte_idx < 38; b++) begin
                tx.tdata[beat][63 - b*8 -: 8] = framed[byte_idx];
                byte_idx++;
            end
        end

        start_item(tx);
        finish_item(tx);
    endtask
endclass
