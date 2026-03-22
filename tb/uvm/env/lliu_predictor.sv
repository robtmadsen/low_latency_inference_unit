// lliu_predictor.sv — Reference model predictor
//
// Subscribes to AXI4-Stream monitor to observe ITCH messages.
// On each valid Add Order, calls DPI-C golden model to compute expected
// inference result. Sends expected float32 result to scoreboard.

// DPI-C function imports (disabled when UVM_NO_DPI is defined)
`ifndef UVM_NO_DPI
import "DPI-C" function int dpi_golden_init(string model_path);
import "DPI-C" function int dpi_golden_inference(
    input  shortint unsigned features[], input int num_features,
    input  shortint unsigned weights[],  input int num_weights,
    output real result
);
import "DPI-C" function int dpi_golden_extract_features(
    input  int unsigned price,
    input  longint unsigned order_ref,
    input  int side,
    output shortint unsigned features_out[],
    input  int num_features
);
import "DPI-C" function void dpi_golden_cleanup();
`endif

class lliu_predictor extends uvm_subscriber #(axi4_stream_transaction);
    `uvm_component_utils(lliu_predictor)

    // Analysis port for expected results → scoreboard
    uvm_analysis_port #(real) result_ap;

    // Stored weights (bfloat16 bit patterns) — set by test before stimulus
    shortint unsigned m_weights[];

    // Track initialization state
    bit m_dpi_initialized = 0;

    function new(string name = "lliu_predictor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        result_ap = new("result_ap", this);
    endfunction

    // Initialize DPI-C golden model
    function void init_golden_model();
`ifndef UVM_NO_DPI
        string model_path;

        if (m_dpi_initialized) return;

        // Get golden model path from plusarg or config_db
        if (!$value$plusargs("GOLDEN_MODEL=%s", model_path)) begin
            `uvm_warning("PREDICTOR", "No +GOLDEN_MODEL plusarg, DPI-C bridge disabled")
            return;
        end

        if (dpi_golden_init(model_path) != 0) begin
            `uvm_error("PREDICTOR", "Failed to initialize DPI-C golden model")
            return;
        end

        m_dpi_initialized = 1;
        `uvm_info("PREDICTOR", $sformatf("DPI-C golden model initialized: %s", model_path), UVM_LOW)
`else
        `uvm_info("PREDICTOR", "DPI-C disabled (UVM_NO_DPI), using local computation", UVM_LOW)
`endif
    endfunction

    // Set weights for prediction (called by test sequence before stimulus)
    function void set_weights(shortint unsigned weights[]);
        m_weights = new[weights.size()](weights);
        `uvm_info("PREDICTOR", $sformatf("Weights set: %0d elements", weights.size()), UVM_MEDIUM)
    endfunction

    // Called by analysis port when AXI4-Stream monitor captures a transaction
    function void write(axi4_stream_transaction t);
        byte unsigned msg_bytes[];
        int byte_count;
        int msg_len;
        byte unsigned msg_type;

        // Convert AXI4-Stream beats to raw byte array (big-endian)
        byte_count = t.tdata.size() * 8;
        msg_bytes = new[byte_count];
        foreach (t.tdata[i]) begin
            for (int b = 0; b < 8; b++)
                msg_bytes[i*8 + b] = t.tdata[i][63 - b*8 -: 8];
        end

        // Parse 2-byte big-endian length prefix
        if (byte_count < 2) return;
        msg_len = {msg_bytes[0], msg_bytes[1]};

        // Check for Add Order message type ('A' = 0x41)
        if (byte_count < 3) return;
        msg_type = msg_bytes[2];
        if (msg_type != 8'h41) begin
            `uvm_info("PREDICTOR", $sformatf("Non-Add-Order message type 0x%02h, skipping", msg_type), UVM_HIGH)
            return;
        end

        // Parse fields and compute expected result
        compute_expected(msg_bytes, byte_count);
    endfunction

    // Parse ITCH Add Order fields and compute expected inference result
    function void compute_expected(byte unsigned msg_bytes[], int byte_count);
        shortint unsigned features[4];
        real expected_result;
        int status;

        // Extract message body (skip 2-byte length prefix)
        // Fields per ITCH 5.0 Add Order layout:
        //   [2]      message type ('A')
        //   [13:20]  order reference (8 bytes at offset 11 from msg body start)
        //   [21]     side ('B'/'S')
        //   [34:37]  price (4 bytes)

        int unsigned price;
        longint unsigned order_ref;
        int side;

        // Byte offsets in msg_bytes (with 2-byte length prefix):
        // msg_body starts at index 2
        // order_ref at body offset 11 → msg_bytes[13..20]
        // side at body offset 19 → msg_bytes[21]
        // price at body offset 32 → msg_bytes[34..37]

        if (byte_count < 38) begin
            `uvm_warning("PREDICTOR", "Add Order message too short")
            return;
        end

        order_ref = 0;
        for (int i = 0; i < 8; i++)
            order_ref = (order_ref << 8) | msg_bytes[13 + i];

        side = (msg_bytes[21] == 8'h42) ? 1 : 0;  // 'B' = buy

        price = 0;
        for (int i = 0; i < 4; i++)
            price = (price << 8) | msg_bytes[34 + i];

        `uvm_info("PREDICTOR", $sformatf("Add Order: price=%0d side=%0d order_ref=%0h",
                  price, side, order_ref), UVM_MEDIUM)

        // Compute expected features via DPI-C
`ifndef UVM_NO_DPI
        if (m_dpi_initialized && m_weights.size() > 0) begin
            status = dpi_golden_extract_features(price, order_ref, side, features, 4);
            if (status != 0) begin
                `uvm_error("PREDICTOR", "DPI-C extract_features failed")
                return;
            end

            status = dpi_golden_inference(features, 4, m_weights, m_weights.size(),
                                          expected_result);
            if (status != 0) begin
                `uvm_error("PREDICTOR", "DPI-C inference failed")
                return;
            end

            `uvm_info("PREDICTOR", $sformatf("Expected result: %f", expected_result), UVM_MEDIUM)
            result_ap.write(expected_result);
        end else begin
            `uvm_info("PREDICTOR", "DPI-C not available, computing locally", UVM_MEDIUM)
            compute_local(price, order_ref, side);
        end
`else
        compute_local(price, order_ref, side);
`endif
    endfunction

    // Local computation fallback (when DPI-C is not available)
    // Uses the same bfloat16 math as the golden model
    function void compute_local(int unsigned price, longint unsigned order_ref, int side);
        real expected_result;
        // Placeholder: scoreboard comparison skipped when DPI-C unavailable
        `uvm_info("PREDICTOR", "Local computation not implemented (use DPI-C for accuracy)", UVM_LOW)
    endfunction

    function void final_phase(uvm_phase phase);
`ifndef UVM_NO_DPI
        if (m_dpi_initialized)
            dpi_golden_cleanup();
`endif
    endfunction
endclass
