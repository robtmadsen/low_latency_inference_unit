// itch_edge_seq.sv — ITCH parser edge-case sequence
//
// Targets uncovered line in itch_parser.sv:
//   - Line 110: state <= S_IDLE on first-beat truncation (tlast with short msg)
// Also exercises:
//   - Non-Add-Order message types (should be dropped)
//   - Back-to-back messages with no idle cycles
//   - Minimum-length and maximum-length messages

class itch_edge_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(itch_edge_seq)

    longint unsigned m_next_order_ref;

    function new(string name = "itch_edge_seq");
        super.new(name);
        m_next_order_ref = 64'hBBBB_0000_0000_0001;
    endfunction

    task body();
        `uvm_info("ITCH_EDGE", "Starting ITCH parser edge-case sequence", UVM_LOW)

        // ---- 1. First-beat truncation: length says 36B but only one beat with tlast
        //         This triggers itch_parser.sv line 110: state <= S_IDLE
        send_first_beat_truncated();

        // ---- 2. Send idle gap then valid Add Order to verify recovery
        send_add_order(m_next_order_ref++, 1, 15000, 100);

        // ---- 3. Non-Add-Order message type 'S' (System Event)
        //         Parser should drop it (not 'A')
        send_non_add_order_msg(8'h53, 12);  // 'S' system event, 12 bytes

        // ---- 4. Non-Add-Order type 'R' (Stock Directory)
        send_non_add_order_msg(8'h52, 36);  // 'R' stock directory, 36 bytes

        // ---- 5. Verify parser still works after dropped messages
        send_add_order(m_next_order_ref++, 0, 25000, 200);

        // ---- 6. Short message (fit in single beat, <= 6 bytes body)
        //         Exercises the short-message fast path
        send_short_msg();

        // ---- 7. Back-to-back valid Add Orders with no idle
        send_add_order(m_next_order_ref++, 1, 5000, 50);
        send_add_order(m_next_order_ref++, 0, 8000, 75);
        send_add_order(m_next_order_ref++, 1, 12000, 100);

        // ---- 8. Multi-beat truncation: declare 36B, send 2 beats (16B) with tlast
        //         Exercises ACCUMULATE → IDLE on premature tlast
        send_accumulate_truncate();

        // ---- 9. Recovery after multi-beat truncation
        send_add_order(m_next_order_ref++, 0, 30000, 150);

        `uvm_info("ITCH_EDGE", "ITCH parser edge-case sequence complete", UVM_LOW)
    endtask

    // First-beat truncation: declares 36-byte msg but sends single beat with tlast
    task send_first_beat_truncated();
        axi4_stream_transaction tx;
        byte unsigned frame[8];

        // Length prefix: 36 (0x0024) in first 2 bytes
        frame[0] = 8'h00;
        frame[1] = 8'h24;
        // Type byte 'A' and some filler
        frame[2] = 8'h41;
        for (int i = 3; i < 8; i++) frame[i] = 8'hDD;

        tx = axi4_stream_transaction::type_id::create("trunc_first");
        tx.tdata = new[1];  // Single beat with implicit tlast
        tx.tdata[0] = '0;
        for (int b = 0; b < 8; b++)
            tx.tdata[0][63 - b*8 -: 8] = frame[b];

        start_item(tx);
        finish_item(tx);
        `uvm_info("ITCH_EDGE", "Sent first-beat truncated message", UVM_MEDIUM)
    endtask

    // Non-Add-Order message — parser should drop
    task send_non_add_order_msg(byte unsigned msg_type, int msg_len);
        byte unsigned framed[];
        axi4_stream_transaction tx;
        int num_beats, byte_idx;

        framed = new[2 + msg_len];
        framed[0] = (msg_len >> 8) & 8'hFF;
        framed[1] =  msg_len       & 8'hFF;
        framed[2] = msg_type;
        for (int i = 3; i < 2 + msg_len; i++)
            framed[i] = 8'hCC;

        num_beats = (framed.size() + 7) / 8;
        tx = axi4_stream_transaction::type_id::create("non_add");
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
        `uvm_info("ITCH_EDGE", $sformatf("Sent non-Add msg type=0x%02h len=%0d",
                  msg_type, msg_len), UVM_MEDIUM)
    endtask

    // Short message (body <= 6 bytes, fits in first beat)
    task send_short_msg();
        axi4_stream_transaction tx;
        byte unsigned frame[8];

        // Length prefix: 4 bytes (0x0004)
        frame[0] = 8'h00;
        frame[1] = 8'h04;
        // Non-Add-Order type so parser drops it
        frame[2] = 8'h48;  // 'H' = Trading Action
        frame[3] = 8'h00;
        frame[4] = 8'h00;
        frame[5] = 8'h00;
        frame[6] = 8'h00;
        frame[7] = 8'h00;

        tx = axi4_stream_transaction::type_id::create("short_msg");
        tx.tdata = new[1];
        tx.tdata[0] = '0;
        for (int b = 0; b < 8; b++)
            tx.tdata[0][63 - b*8 -: 8] = frame[b];

        start_item(tx);
        finish_item(tx);
        `uvm_info("ITCH_EDGE", "Sent short message (4B body)", UVM_MEDIUM)
    endtask

    // Multi-beat truncation: declare 36B, send only 2 beats (16B) then tlast
    task send_accumulate_truncate();
        axi4_stream_transaction tx;
        byte unsigned raw[16];

        // Length prefix: 36 bytes
        raw[0] = 8'h00;
        raw[1] = 8'h24;
        // Type 'A' and partial body
        raw[2] = 8'h41;
        for (int i = 3; i < 16; i++) raw[i] = 8'hEE;

        tx = axi4_stream_transaction::type_id::create("accum_trunc");
        tx.tdata = new[2];  // 2 beats = 16 bytes, but msg declares 36
        for (int beat = 0; beat < 2; beat++) begin
            tx.tdata[beat] = '0;
            for (int b = 0; b < 8; b++)
                tx.tdata[beat][63 - b*8 -: 8] = raw[beat*8 + b];
        end

        start_item(tx);
        finish_item(tx);
        `uvm_info("ITCH_EDGE", "Sent multi-beat truncated message (16B of 36B)", UVM_MEDIUM)
    endtask

    // Standard Add Order helper
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
        msg[24] = "E"; msg[25] = "D"; msg[26] = "G"; msg[27] = "E";
        msg[28] = " "; msg[29] = " "; msg[30] = " "; msg[31] = " ";
        msg[32] = (price >> 24) & 8'hFF;
        msg[33] = (price >> 16) & 8'hFF;
        msg[34] = (price >>  8) & 8'hFF;
        msg[35] =  price        & 8'hFF;

        framed = new[38];
        framed[0] = (36 >> 8) & 8'hFF;
        framed[1] =  36       & 8'hFF;
        for (int i = 0; i < 36; i++)
            framed[2 + i] = msg[i];

        num_beats = (framed.size() + 7) / 8;
        tx = axi4_stream_transaction::type_id::create("add_order");
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
