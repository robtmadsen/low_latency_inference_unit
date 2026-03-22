// lliu_scoreboard.sv — UVM scoreboard for inference result checking
//
// Compares expected results (from predictor via DPI-C golden model)
// against actual results (from AXI4-Lite monitor on result register reads).
//
// Result register address: 0x10 (RESULT)

class lliu_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(lliu_scoreboard)

    // Result register address
    localparam bit [31:0] REG_RESULT = 32'h10;

    // Analysis exports
    uvm_analysis_imp_decl(_expected)
    uvm_analysis_imp_decl(_actual)

    uvm_analysis_imp_expected #(real, lliu_scoreboard)                 expected_export;
    uvm_analysis_imp_actual   #(axi4_lite_transaction, lliu_scoreboard) actual_export;

    // Expected result queue
    real m_expected_q[$];

    // Statistics
    int m_total_compared  = 0;
    int m_total_mismatches = 0;
    int m_total_expected   = 0;
    int m_total_actual     = 0;

    function new(string name = "lliu_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        expected_export = new("expected_export", this);
        actual_export   = new("actual_export", this);
    endfunction

    // Receive expected result from predictor
    function void write_expected(real expected);
        m_expected_q.push_back(expected);
        m_total_expected++;
        `uvm_info("SCOREBOARD", $sformatf("Expected result queued: %f (queue depth: %0d)",
                  expected, m_expected_q.size()), UVM_HIGH)
    endfunction

    // Receive actual AXI4-Lite transaction from monitor
    // Only process reads from the RESULT register (0x10)
    function void write_actual(axi4_lite_transaction tx);
        real actual_float;
        real expected;

        // Filter: only care about reads from RESULT register
        if (tx.is_write || tx.addr != REG_RESULT)
            return;

        m_total_actual++;

        // Convert 32-bit result register value to float
        actual_float = bits_to_float(tx.rdata);

        `uvm_info("SCOREBOARD", $sformatf("Actual result read: 0x%08h = %f",
                  tx.rdata, actual_float), UVM_MEDIUM)

        // Compare against expected
        if (m_expected_q.size() == 0) begin
            `uvm_warning("SCOREBOARD",
                $sformatf("Actual result received but no expected result in queue (result=%f)",
                          actual_float))
            return;
        end

        expected = m_expected_q.pop_front();
        m_total_compared++;

        // Exact match required (deterministic pipeline, same bfloat16 math)
        if (float_to_bits(actual_float) !== float_to_bits(expected)) begin
            m_total_mismatches++;
            `uvm_error("SCOREBOARD",
                $sformatf("MISMATCH #%0d: expected=%f (0x%08h) actual=%f (0x%08h)",
                          m_total_mismatches,
                          expected, float_to_bits(expected),
                          actual_float, float_to_bits(actual_float)))
        end else begin
            `uvm_info("SCOREBOARD",
                $sformatf("MATCH #%0d: %f", m_total_compared, actual_float), UVM_MEDIUM)
        end
    endfunction

    // Convert bit [31:0] to real (float32 interpretation)
    function real bits_to_float(bit [31:0] bits);
        shortreal sr;
        // SystemVerilog $bitstoshortreal
        sr = $bitstoshortreal(bits);
        return real'(sr);
    endfunction

    // Convert real to bit [31:0]
    function bit [31:0] float_to_bits(real f);
        shortreal sr;
        sr = shortreal'(f);
        return $shortrealtobits(sr);
    endfunction

    function void check_phase(uvm_phase phase);
        if (m_expected_q.size() > 0)
            `uvm_error("SCOREBOARD",
                $sformatf("%0d expected results not consumed", m_expected_q.size()))
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SCOREBOARD", "========== Scoreboard Report ==========", UVM_NONE)
        `uvm_info("SCOREBOARD", $sformatf("  Expected received:  %0d", m_total_expected), UVM_NONE)
        `uvm_info("SCOREBOARD", $sformatf("  Actual received:    %0d", m_total_actual), UVM_NONE)
        `uvm_info("SCOREBOARD", $sformatf("  Compared:           %0d", m_total_compared), UVM_NONE)
        `uvm_info("SCOREBOARD", $sformatf("  Mismatches:         %0d", m_total_mismatches), UVM_NONE)
        `uvm_info("SCOREBOARD", "=======================================", UVM_NONE)
    endfunction
endclass
