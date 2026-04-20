// latency_histogram.sv — 32-bin cycle-count latency histogram
/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */
/* verilator lint_off UNUSEDSIGNAL */
module latency_histogram (
    input  logic        clk,
    input  logic        rst,
    input  logic [73:0] t_start,
    input  logic        t_start_valid,
    input  logic [73:0] t_end,
    input  logic        t_end_valid,
    input  logic [4:0]  axil_bin_addr,
    output logic [31:0] axil_bin_data,
    input  logic        axil_clear,
    output logic [31:0] overflow_bin
);
    (* ram_style = "distributed" *) logic [31:0] hist_bins [0:31];
    logic [31:0] overflow_r;
    logic [73:0] t_start_r;
    logic        t_start_held;
    // Stage-1 pipeline registers: register delta after subtraction so Stage-2
    // (bin increment) sees only FDREs, breaking the 14-level CARRY chain path
    // (timestamp_out → 10-bit sub → fo=505 → 32-bit increment, WNS=-0.795ns).
    logic [4:0]  delta_r;       // registered bin index (capped at 31)
    logic        delta_ovf_r;   // registered overflow flag
    logic        delta_valid_r; // pipeline valid

    // Stage 1: capture t_start, compute delta, register result
    always_ff @(posedge clk) begin
        if (rst) begin
            t_start_held  <= 1'b0;
            t_start_r     <= '0;
            delta_r       <= '0;
            delta_ovf_r   <= 1'b0;
            delta_valid_r <= 1'b0;
        end else begin
            delta_valid_r <= 1'b0;
            if (t_start_valid) begin
                t_start_r    <= t_start;
                t_start_held <= 1'b1;
            end
            if (t_end_valid && t_start_held) begin
                automatic logic [9:0] delta;
                delta = t_end[9:0] - t_start_r[9:0];
                t_start_held  <= 1'b0;
                delta_valid_r <= 1'b1;
                delta_ovf_r   <= (delta > 10'd31);
                delta_r       <= delta[4:0];
            end
        end
    end

    // Stage 1.5: pre-register the selected bin value and control signals.
    // Run 28 fix: eliminates the 32:1 read-MUX (MUXF7+LUT6, fo=121 on delta_r)
    // from the critical path.  Before this, Stage 2 saw:
    //   delta_r → 32:1 MUX (3 levels) → CARRY4×8 (8 levels) → hist_bins_reg
    //   = 12 levels, 3.505 ns.  After, Stage 2 sees:
    //   sel_bin_r (FDRE) → CARRY4×8 → hist_bins_reg = 9 levels, ~2.0 ns.
    logic [31:0] sel_bin_r;    // pre-read hist_bins[delta_r]
    logic [4:0]  sel_idx_r;    // registered bin address
    logic        sel_ovf_r;
    logic        sel_valid_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            sel_bin_r   <= '0;
            sel_idx_r   <= '0;
            sel_ovf_r   <= 1'b0;
            sel_valid_r <= 1'b0;
        end else begin
            sel_bin_r   <= hist_bins[delta_r];   // 32:1 MUX → FDRE (not on crit path)
            sel_idx_r   <= delta_r;
            sel_ovf_r   <= delta_ovf_r;
            sel_valid_r <= delta_valid_r;
        end
    end

    // Stage 2: increment and write back.
    // Critical path: sel_bin_r (FDRE) → CARRY4×8 → per-bin LUT → hist_bins_reg.
    // Write hazard: consecutive events to the same bin within 1 cycle miss one
    // count — acceptable for a monitoring histogram.
    always_ff @(posedge clk) begin
        if (rst) begin
            overflow_r <= '0;
            for (int i = 0; i < 32; i++) hist_bins[i] <= '0;
        end else begin
            if (axil_clear) begin
                for (int i = 0; i < 32; i++) hist_bins[i] <= '0;
                overflow_r <= '0;
            end
            if (sel_valid_r) begin
                if (sel_ovf_r)
                    overflow_r <= overflow_r + 1;
                else
                    hist_bins[sel_idx_r] <= sel_bin_r + 1;
            end
        end
    end
    assign axil_bin_data = hist_bins[axil_bin_addr];
    assign overflow_bin  = overflow_r;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
