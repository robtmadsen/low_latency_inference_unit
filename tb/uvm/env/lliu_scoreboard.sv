// lliu_scoreboard.sv — UVM scoreboard for inference result checking
//
// Compares expected results (from predictor via DPI-C golden model)
// against actual results (from AXI4-Lite monitor on result register reads).
//
// Uses uvm_tlm_analysis_fifo (Verilator-compatible) instead of
// uvm_analysis_imp_decl macros.
//
// Result register address: 0x10 (RESULT)

class lliu_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(lliu_scoreboard)

    // Result register address
    localparam bit [31:0] REG_RESULT = 32'h10;

    // Analysis FIFOs (Verilator-compatible replacement for uvm_analysis_imp_decl)
    uvm_tlm_analysis_fifo #(real)                  expected_fifo;
    uvm_tlm_analysis_fifo #(axi4_lite_transaction) actual_fifo;

    // Statistics
    int m_total_compared   = 0;
    int m_total_mismatches = 0;
    int m_total_actual     = 0;

    function new(string name = "lliu_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        expected_fifo = new("expected_fifo", this);
        actual_fifo   = new("actual_fifo", this);
    endfunction

    // Main comparison loop: blocks on actual FIFO, checks expected FIFO
    task run_phase(uvm_phase phase);
        axi4_lite_transaction tx;
        real expected;
        real actual_float;

        forever begin
            actual_fifo.get(tx);

            // Filter: only care about reads from RESULT register
            if (tx.is_write || tx.addr != REG_RESULT)
                continue;

            m_total_actual++;
            actual_float = bits_to_float(tx.rdata);

            `uvm_info("SCOREBOARD", $sformatf("Actual result read: 0x%08h = %f",
                      tx.rdata, actual_float), UVM_MEDIUM)

            if (!expected_fifo.try_get(expected)) begin
                `uvm_warning("SCOREBOARD",
                    $sformatf("Actual result received but no expected result in queue (result=%f)",
                              actual_float))
                continue;
            end

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
        end
    endtask

    // Convert fp32 bits → real via manual IEEE-754 widening (no shortreal)
    function real bits_to_float(bit [31:0] bits);
        bit          sign;
        bit [7:0]    exp8;
        bit [22:0]   mant23;
        bit [10:0]   exp11;
        bit [51:0]   mant52;
        bit [63:0]   bits64;

        sign   = bits[31];
        exp8   = bits[30:23];
        mant23 = bits[22:0];

        if (exp8 == 0 && mant23 == 0)
            return sign ? $bitstoreal(64'h8000_0000_0000_0000) : 0.0;

        if (exp8 == 8'hFF) begin
            exp11  = 11'h7FF;
            mant52 = {mant23, 29'b0};
        end else begin
            exp11  = 11'(int'(exp8) - 127 + 1023);
            mant52 = {mant23, 29'b0};
        end

        bits64 = {sign, exp11, mant52};
        return $bitstoreal(bits64);
    endfunction

    // Convert real → fp32 bits via manual IEEE-754 narrowing (no shortreal)
    function bit [31:0] float_to_bits(real f);
        bit [63:0]   bits64;
        bit          sign;
        bit [10:0]   exp11;
        int          exp_unbiased;
        bit [7:0]    exp8;
        bit [51:0]   mant52;
        bit [22:0]   mant23;

        bits64 = $realtobits(f);
        sign   = bits64[63];
        exp11  = bits64[62:52];
        mant52 = bits64[51:0];

        if (exp11 == 0)
            return {sign, 31'b0};

        if (exp11 == 11'h7FF)
            return {sign, 8'hFF, mant52[51:29]};

        exp_unbiased = int'(exp11) - 1023;

        if (exp_unbiased + 127 <= 0)
            return {sign, 31'b0};
        if (exp_unbiased + 127 >= 255)
            return {sign, 8'hFF, 23'b0};

        exp8   = 8'(exp_unbiased + 127);
        mant23 = mant52[51:29];
        return {sign, exp8, mant23};
    endfunction

    function void check_phase(uvm_phase phase);
        int remaining = expected_fifo.used();
        if (remaining > 0)
            `uvm_error("SCOREBOARD",
                $sformatf("%0d expected results not consumed", remaining))
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SCOREBOARD", "========== Scoreboard Report ==========", UVM_NONE)
        `uvm_info("SCOREBOARD", $sformatf("  Actual reads:       %0d", m_total_actual), UVM_NONE)
        `uvm_info("SCOREBOARD", $sformatf("  Compared:           %0d", m_total_compared), UVM_NONE)
        `uvm_info("SCOREBOARD", $sformatf("  Mismatches:         %0d", m_total_mismatches), UVM_NONE)
        `uvm_info("SCOREBOARD", "=======================================", UVM_NONE)
    endfunction
endclass
