// backpressure_seq.sv — AXI4-Stream backpressure / inter-message delay sequence
//
// Adds configurable inter-message spacing to stress pipeline fill/drain.
// The AXI4-Stream driver already respects tready (DUT is the slave).
// This sequence controls sender-side pacing via clock delays between
// successive Add Order transactions.

class backpressure_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(backpressure_seq)

    // ----------------------------------------------------------------
    // Configuration
    // ----------------------------------------------------------------
    // Pattern: 0 = none (max throughput), 1 = periodic stall, 2 = pseudo-random
    int unsigned pattern      = 0;
    int unsigned ready_every  = 4;   // periodic: stall every N messages
    int unsigned stall_ns     = 50;  // periodic: nanoseconds to stall
    int unsigned max_rand_ns  = 100; // random: max ns between messages
    int unsigned num_messages = 50;

    // ----------------------------------------------------------------
    // Internal
    // ----------------------------------------------------------------
    longint unsigned m_next_order_ref;

    function new(string name = "backpressure_seq");
        super.new(name);
        m_next_order_ref = 64'h0000_0002_0000_0000;
    endfunction

    task body();
        `uvm_info("BP_SEQ", $sformatf("Backpressure pattern=%0d, %0d msgs",
                  pattern, num_messages), UVM_LOW)

        for (int i = 0; i < num_messages; i++) begin
            send_add_order(m_next_order_ref,
                           .side(i[0] ? 1'b0 : 1'b1),
                           .price(1000 + i * 100),
                           .shares(100));
            m_next_order_ref++;

            case (pattern)
                0: ; // back-to-back

                1: begin  // periodic stall
                    if ((i + 1) % ready_every == 0)
                        #(stall_ns * 1ns);
                end

                2: begin  // deterministic pseudo-random stall
                    int unsigned delay_ns;
                    delay_ns = (i * 6700417 + 1) % (max_rand_ns + 1);
                    if (delay_ns > 0)
                        #(delay_ns * 1ns);
                end
            endcase
        end

        `uvm_info("BP_SEQ", $sformatf("Sent %0d messages", num_messages), UVM_LOW)
    endtask

    // ----------------------------------------------------------------
    // Build and send a single ITCH Add Order transaction
    // ----------------------------------------------------------------
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
