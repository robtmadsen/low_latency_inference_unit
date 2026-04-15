// axis_raw_seq.sv — One-shot AXI4-Stream sequence for driving raw beat arrays
//
// Wraps a pre-built array of 64-bit beats into a single axi4_stream_transaction
// so that sequences (and tests) can drive frames without inheriting from
// uvm_sequence_base directly.  Call .start(axis_agent.m_sequencer) to send.
//
// Usage:
//   axis_raw_seq s;
//   s = axis_raw_seq::type_id::create("raw_sq");
//   s.beats = new[beats.size()](beats);
//   s.start(m_env.m_axis_agent.m_sequencer);

class axis_raw_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(axis_raw_seq)

    bit [63:0] beats[];

    function new(string name = "axis_raw_seq");
        super.new(name);
    endfunction

    task body();
        axi4_stream_transaction tx;
        tx = axi4_stream_transaction::type_id::create("tx");
        tx.tdata = new[beats.size()](beats);
        start_item(tx);
        finish_item(tx);
    endtask
endclass
