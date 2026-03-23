// itch_error_seq.sv — Adversarial ITCH message sequence for error injection
//
// Sends intentionally malformed messages to verify parser recovery:
//   - Truncated: short body relative to declared length
//   - Bad type:  invalid message type code (0xFF)
//   - Garbage:   random bytes with no valid framing
// Each malformed packet is followed by a valid Add Order to verify recovery.

class itch_error_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(itch_error_seq)

    longint unsigned m_next_order_ref;

    function new(string name = "itch_error_seq");
        super.new(name);
        m_next_order_ref = 64'hDEAD_0000_0000_0001;
    endfunction

    task body();
        byte unsigned raw[];
        `uvm_info("ERR_SEQ", "Starting error injection sequence", UVM_LOW)

        // ---- Test 1: Truncated message ----
        get_truncated_msg(raw);
        send_raw_bytes(raw, "truncated");
        send_recovery_idles(10);
        send_add_order(m_next_order_ref++, 1, 5000, 100);

        // ---- Test 2: Bad message type ----
        get_bad_type_msg(raw);
        send_raw_bytes(raw, "bad_type");
        send_recovery_idles(10);
        send_add_order(m_next_order_ref++, 0, 12000, 100);

        // ---- Test 3: Garbage bytes ----
        get_garbage_msg(raw);
        send_raw_bytes(raw, "garbage");
        send_recovery_idles(10);
        send_add_order(m_next_order_ref++, 1, 8000, 100);

        `uvm_info("ERR_SEQ", "Error injection sequence complete", UVM_LOW)
    endtask

    // ----------------------------------------------------------------
    // Message constructors — return raw byte arrays
    // ----------------------------------------------------------------

    // Truncated: declares 36 bytes but only sends 10-byte body
    function automatic void get_truncated_msg(output byte unsigned raw[]);
        raw = new[12];
        raw[0] = 8'h00;
        raw[1] = 8'h24;   // declares 36 bytes
        for (int i = 2; i < 12; i++) raw[i] = 8'hAA;
    endfunction

    // Bad type: full 38B frame but type byte = 0xFF
    function automatic void get_bad_type_msg(output byte unsigned raw[]);
        raw = new[38];
        raw[0] = 8'h00;
        raw[1] = 8'h24;
        raw[2] = 8'hFF;
        for (int i = 3; i < 38; i++) raw[i] = 8'hBB;
    endfunction

    // Garbage: 16 bytes with no valid ITCH framing
    function automatic void get_garbage_msg(output byte unsigned raw[]);
        raw = new[16];
        for (int i = 0; i < 16; i++)
            raw[i] = byte'((i * 37 + 13) & 8'hFF);
    endfunction

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    task send_recovery_idles(int unsigned n);
        axi4_stream_transaction idle;
        repeat(n) begin
            idle = axi4_stream_transaction::type_id::create("idle");
            idle.tdata = new[1];
            idle.tdata[0] = '0;
            start_item(idle);
            finish_item(idle);
        end
    endtask

    task send_raw_bytes(byte unsigned raw[], string tag);
        axi4_stream_transaction tx;
        int num_beats, byte_idx;
        int raw_len;

        raw_len = raw.size();
        num_beats = (raw_len + 7) / 8;
        tx = axi4_stream_transaction::type_id::create(tag);
        tx.tdata = new[num_beats];
        byte_idx = 0;
        for (int beat = 0; beat < num_beats; beat++) begin
            tx.tdata[beat] = '0;
            for (int b = 0; b < 8 && byte_idx < raw_len; b++) begin
                tx.tdata[beat][63 - b*8 -: 8] = raw[byte_idx];
                byte_idx++;
            end
        end
        start_item(tx);
        finish_item(tx);
        `uvm_info("ERR_SEQ", $sformatf("Sent %s (%0d bytes)", tag, raw_len), UVM_MEDIUM)
    endtask

    task send_add_order(longint unsigned order_ref, bit side,
                        int unsigned price, int unsigned shares);
        byte unsigned msg[36];
        byte unsigned framed[];
        axi4_stream_transaction tx;
        int num_beats, byte_idx;

        msg[0] = 8'h41;
        for (int i = 1; i < 11; i++) msg[i] = 0;
        for (int i = 0; i < 8; i++)
            msg[11 + i] = (order_ref >> (56 - i*8)) & 8'hFF;
        msg[19] = side ? 8'h42 : 8'h53;
        msg[20] = (shares >> 24) & 8'hFF;
        msg[21] = (shares >> 16) & 8'hFF;
        msg[22] = (shares >>  8) & 8'hFF;
        msg[23] =  shares        & 8'hFF;
        msg[24] = "T"; msg[25] = "E"; msg[26] = "S"; msg[27] = "T";
        msg[28] = " "; msg[29] = " "; msg[30] = " "; msg[31] = " ";
        msg[32] = (price >> 24) & 8'hFF;
        msg[33] = (price >> 16) & 8'hFF;
        msg[34] = (price >>  8) & 8'hFF;
        msg[35] =  price        & 8'hFF;

        framed = new[38];
        framed[0] = 8'h00;
        framed[1] = 8'h24;
        for (int i = 0; i < 36; i++) framed[2 + i] = msg[i];

        num_beats = (38 + 7) / 8;
        tx = axi4_stream_transaction::type_id::create("valid_ado");
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
        `uvm_info("ERR_SEQ", $sformatf("Sent recovery Add Order ref=%0d", order_ref), UVM_MEDIUM)
    endtask
endclass
