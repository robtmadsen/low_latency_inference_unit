// itch_replay_seq.sv — ITCH message replay sequence
//
// Constructs ITCH messages and sends them as AXI4-Stream transactions.
// Supports:
//   - Single synthetic Add Order (for smoke tests)
//   - Binary file replay (for real data tests)
//
// ITCH framing: 2-byte big-endian length prefix + message body
// AXI4-Stream: 64-bit beats, big-endian byte order

class itch_replay_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(itch_replay_seq)

    // Configuration
    string m_data_file = "";    // Path to binary ITCH file (empty = synthetic only)
    int    m_max_messages = 0;  // 0 = all messages in file
    bit    m_inject_add_orders = 0;

    // Synthetic Add Order parameters
    typedef struct {
        longint unsigned order_ref;
        bit              side;      // 1=buy, 0=sell
        int unsigned     shares;
        int unsigned     price;
        byte unsigned    stock[8];
    } add_order_t;

    add_order_t m_synthetic_orders[$];

    function new(string name = "itch_replay_seq");
        super.new(name);
    endfunction

    // Add a synthetic Add Order to the queue
    function void add_order(
        longint unsigned order_ref,
        bit              side,
        int unsigned     price,
        int unsigned     shares = 100,
        string           stock  = "AAPL    "
    );
        add_order_t o;
        o.order_ref = order_ref;
        o.side      = side;
        o.shares    = shares;
        o.price     = price;
        foreach (stock[i])
            if (i < 8) o.stock[i] = stock[i];
        m_synthetic_orders.push_back(o);
    endfunction

    task body();
        if (m_data_file != "")
            replay_file();

        // Send any synthetic Add Orders
        foreach (m_synthetic_orders[i])
            send_add_order(m_synthetic_orders[i]);
    endtask

    // Construct and send a single ITCH Add Order message
    task send_add_order(add_order_t o);
        byte unsigned msg[36];
        byte unsigned framed[];
        int idx;

        // Build Add Order body (36 bytes)
        msg[0] = 8'h41;  // 'A' = Add Order

        // stock_locate (2 bytes) = 0
        msg[1] = 0; msg[2] = 0;
        // tracking_number (2 bytes) = 0
        msg[3] = 0; msg[4] = 0;
        // timestamp (6 bytes) = 0
        for (int i = 5; i < 11; i++) msg[i] = 0;

        // order_reference_number (8 bytes, big-endian)
        for (int i = 0; i < 8; i++)
            msg[11 + i] = (o.order_ref >> (56 - i*8)) & 8'hFF;

        // buy_sell_indicator (1 byte)
        msg[19] = o.side ? 8'h42 : 8'h53;  // 'B' or 'S'

        // shares (4 bytes, big-endian)
        msg[20] = (o.shares >> 24) & 8'hFF;
        msg[21] = (o.shares >> 16) & 8'hFF;
        msg[22] = (o.shares >>  8) & 8'hFF;
        msg[23] =  o.shares        & 8'hFF;

        // stock (8 bytes)
        for (int i = 0; i < 8; i++)
            msg[24 + i] = o.stock[i];

        // price (4 bytes, big-endian)
        msg[32] = (o.price >> 24) & 8'hFF;
        msg[33] = (o.price >> 16) & 8'hFF;
        msg[34] = (o.price >>  8) & 8'hFF;
        msg[35] =  o.price        & 8'hFF;

        // Frame with 2-byte big-endian length prefix
        framed = new[38];
        framed[0] = (36 >> 8) & 8'hFF;
        framed[1] =  36       & 8'hFF;
        for (int i = 0; i < 36; i++)
            framed[2 + i] = msg[i];

        send_framed_message(framed);
    endtask

    // Send a framed ITCH message as AXI4-Stream beats
    task send_framed_message(byte unsigned framed[]);
        axi4_stream_transaction tx;
        int num_beats;
        int byte_idx;

        num_beats = (framed.size() + 7) / 8;
        tx = axi4_stream_transaction::type_id::create("tx");
        tx.tdata = new[num_beats];

        byte_idx = 0;
        for (int beat = 0; beat < num_beats; beat++) begin
            tx.tdata[beat] = '0;
            for (int b = 0; b < 8 && byte_idx < framed.size(); b++) begin
                // Big-endian: byte 0 → tdata[63:56]
                tx.tdata[beat][63 - b*8 -: 8] = framed[byte_idx];
                byte_idx++;
            end
        end

        start_item(tx);
        finish_item(tx);
    endtask

    // Replay messages from a binary ITCH file
    task replay_file();
        int fd;
        byte unsigned len_buf[2];
        int msg_len;
        byte unsigned msg_body[];
        byte unsigned framed[];
        int msg_count;
        int bytes_read;
        byte unsigned tmp_byte;

        fd = $fopen(m_data_file, "rb");
        if (fd == 0) begin
            `uvm_error("REPLAY", $sformatf("Failed to open file: %s", m_data_file))
            return;
        end

        `uvm_info("REPLAY", $sformatf("Replaying ITCH data from: %s", m_data_file), UVM_LOW)

        msg_count = 0;
        while (!$feof(fd)) begin
            if (m_max_messages > 0 && msg_count >= m_max_messages) break;

            // Read 2-byte big-endian length prefix
            bytes_read = $fread(tmp_byte, fd);
            if (bytes_read < 1) break;
            len_buf[0] = tmp_byte;
            bytes_read = $fread(tmp_byte, fd);
            if (bytes_read < 1) break;
            len_buf[1] = tmp_byte;

            msg_len = {len_buf[0], len_buf[1]};
            if (msg_len == 0 || msg_len > 1024) break;

            // Read message body
            msg_body = new[msg_len];
            for (int i = 0; i < msg_len; i++) begin
                bytes_read = $fread(tmp_byte, fd);
                if (bytes_read < 1) break;
                msg_body[i] = tmp_byte;
            end

            // Frame and send
            framed = new[2 + msg_len];
            framed[0] = len_buf[0];
            framed[1] = len_buf[1];
            for (int i = 0; i < msg_len; i++)
                framed[2 + i] = msg_body[i];

            send_framed_message(framed);
            msg_count++;
        end

        $fclose(fd);
        `uvm_info("REPLAY", $sformatf("Replayed %0d messages", msg_count), UVM_LOW)
    endtask
endclass
