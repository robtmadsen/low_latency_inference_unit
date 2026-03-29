// moldupp64_seq.sv — Constrained-random MoldUDP64 datagram sequence
//
// Generates MoldUDP64 datagrams as AXI4-S beats and drives them via the
// axi4_stream_agent sequencer.  Used by lliu_moldupp64_test.
//
// MoldUDP64 header (20 bytes):
//   bytes  0– 9: Session (10 ASCII bytes, default "TESTSESS  ")
//   bytes 10–17: Sequence Number (big-endian uint64)
//   bytes 18–19: Message Count (big-endian uint16)
//   bytes 20+  : ITCH payload (4 bytes of test data)
//
// Byte-order convention (matches moldupp64_strip.sv tdata_byte function):
//   Byte N of datagram → tdata[N%8 * 8 +: 8]
//   → tdata = { byte[base+7], byte[base+6], ..., byte[base+0] }  (SV concat)
//   → tdata[k*8 +: 8] = datagram_byte[base + k]
//
// Payload is always 4 bytes (total datagram = 24 bytes = 3 full 8-byte beats,
// tkeep = 0xFF on every beat).  The AXI4-S interface does not carry tkeep;
// tkeep is driven separately in tb_top (tied to 0xFF for MOLDUPP64_DUT).
//
// Modes (select via rand constraints before randomize):
//   MODE_NORMAL — in-order datagram (seq_num == last_accepted + last_msg_count)
//   MODE_GAP    — gap: seq_num > expected → drop expected in DUT
//   MODE_DUP    — duplicate: seq_num < expected → drop expected in DUT

class moldupp64_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(moldupp64_seq)

    // -----------------------------------------------------------
    // Sequence parameters (configure before start)
    // -----------------------------------------------------------
    // How many datagrams to send
    rand int unsigned num_datagrams;
    constraint c_num_datagrams { num_datagrams inside {[1:200]}; }

    // Inject error mode for the NEXT datagram
    typedef enum { MODE_NORMAL, MODE_GAP, MODE_DUP } seq_mode_t;
    seq_mode_t mode;

    // msg_count per datagram (DUT advances expected_seq_num by this)
    rand bit [15:0] msg_count;
    constraint c_msg_count { msg_count inside {1, [2:4], [5:15], [16:64]}; }

    // -----------------------------------------------------------
    // Internal state (tracks in-order sequence number)
    // -----------------------------------------------------------
    bit [63:0] m_last_seq_num;   // seq_num of the last sent datagram
    bit [15:0] m_last_msg_count; // msg_count of the last sent datagram
    bit [63:0] m_expected_seq;   // expected_seq_num as tracked by this sequence

    // Session identifier (10 ASCII bytes, padded to right with spaces)
    local byte unsigned m_session[10] = '{
        "T","E","S","T","S","E","S","S"," "," "
    };

    function new(string name = "moldupp64_seq");
        super.new(name);
        m_expected_seq   = 64'd1;  // MoldUDP64 sequences start at 1
        m_last_seq_num   = 64'd0;
        m_last_msg_count = 16'd0;
        mode             = MODE_NORMAL;
        num_datagrams    = 1;
        msg_count        = 16'd1;
    endfunction

    // -----------------------------------------------------------
    // body
    // -----------------------------------------------------------
    task body();
        `uvm_info("MOLDUPP64_SEQ",
            $sformatf("Sending %0d datagrams (mode=%0s)", num_datagrams, mode.name()),
            UVM_LOW)

        for (int i = 0; i < num_datagrams; i++) begin
            bit [63:0] this_seq_num;
            bit [15:0] this_msg_count;

            // Determine seq_num based on mode
            case (mode)
                MODE_GAP: begin
                    this_seq_num   = m_expected_seq + 5;  // skip 5 ahead
                    this_msg_count = msg_count;
                end
                MODE_DUP: begin
                    if (m_expected_seq > 1)
                        this_seq_num = m_expected_seq - 1; // replay previous
                    else
                        this_seq_num = 64'd0;              // before start
                    this_msg_count = msg_count;
                end
                default: begin  // MODE_NORMAL
                    this_seq_num   = m_expected_seq;
                    this_msg_count = msg_count;
                end
            endcase

            send_datagram(this_seq_num, this_msg_count);

            // Only advance expected state if in-order
            if (mode == MODE_NORMAL) begin
                m_last_seq_num   = this_seq_num;
                m_last_msg_count = this_msg_count;
                m_expected_seq   = this_seq_num + this_msg_count;
            end
        end

        `uvm_info("MOLDUPP64_SEQ",
            $sformatf("Done. Last expected_seq_num=%0d", m_expected_seq),
            UVM_LOW)
    endtask

    // -----------------------------------------------------------
    // Helper: build and send one datagram
    // Datagram = 20-byte header + 4-byte payload = 24 bytes = 3 full beats
    // -----------------------------------------------------------
    task send_datagram(bit [63:0] seq_num, bit [15:0] this_msg_count);
        byte unsigned dgram[24];
        axi4_stream_transaction tx;
        int beat;

        // Session bytes 0–9
        for (int i = 0; i < 10; i++) dgram[i] = m_session[i];

        // Sequence Number (big-endian uint64) bytes 10–17
        for (int i = 0; i < 8; i++)
            dgram[10 + i] = (seq_num >> (56 - i*8)) & 8'hFF;

        // Message Count (big-endian uint16) bytes 18–19
        dgram[18] = (this_msg_count >> 8) & 8'hFF;
        dgram[19] = this_msg_count & 8'hFF;

        // Payload bytes 20–23: use seq_num low 32 bits as recognisable pattern
        dgram[20] = (seq_num >> 24) & 8'hFF;
        dgram[21] = (seq_num >> 16) & 8'hFF;
        dgram[22] = (seq_num >>  8) & 8'hFF;
        dgram[23] =  seq_num        & 8'hFF;

        // Pack 24 bytes into 3 AXI4-Stream beats (little-endian within each beat)
        tx = axi4_stream_transaction::type_id::create("tx");
        tx.tdata = new[3];
        for (beat = 0; beat < 3; beat++) begin
            tx.tdata[beat] = 64'h0;
            for (int k = 0; k < 8; k++)
                tx.tdata[beat][k*8 +: 8] = dgram[beat*8 + k];
        end

        start_item(tx);
        finish_item(tx);

        `uvm_info("MOLDUPP64_SEQ",
            $sformatf("  sent seq_num=%0d msg_count=%0d", seq_num, this_msg_count),
            UVM_HIGH)
    endtask

endclass
