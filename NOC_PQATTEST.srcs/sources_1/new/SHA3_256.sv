`timescale 1ns/1ps

module sha3_256
    import keccak_pkg::*;
    import sha3_pkg::*;
(
    input  logic                             clk,
    input  logic                             rst_n,

    input  logic                             start,

    input  logic [RATE_BITS-1:0]             msg_block_in,
    input  logic [$clog2(RATE_BYTES+1)-1:0]  valid_bytes,
    input  logic                             is_final,

    output logic [DIGEST_BITS-1:0]           digest,
    output logic                             busy,
    output logic                             done
);

    // ====================================================================
    // INTERNAL STATE
    // ====================================================================

    state_t state_reg;
    state_t padded_state;
    state_t permuted_state;

    logic [RATE_BITS-1:0] padded_block;

    logic keccak_start;
    logic keccak_busy;
    logic keccak_done;


    // ====================================================================
    // SHA3 PADDING
    // ====================================================================

    sha3_pad u_sha3_pad (
        .msg_block_in (msg_block_in),
        .valid_bytes  (valid_bytes),
        .is_final     (is_final),
        .padded_block (padded_block)
    );


    // ====================================================================
    // SHA3 ABSORB
    // ====================================================================

    sha3_absorb u_sha3_absorb (
        .state_in  (state_reg),
        .block_in  (padded_block),
        .state_out (padded_state)
    );


    // ====================================================================
    // KECCAK-F[1600]
    // ====================================================================

    keccak_f1600 u_keccak_f1600 (
        .clk       (clk),
        .rst       (~rst_n),
        .start     (keccak_start),
        .state_in  (state_reg),
        .state_out (permuted_state),
        .busy      (keccak_busy),
        .done      (keccak_done)
    );


    // ====================================================================
    // DIGEST SERIALIZATION
    //
    // Project byte-order contract:
    //
    //     digest[i*8 +: 8] = digest byte i
    //
    // SHA3-256 requires the first four lanes:
    //
    //     lane 0 -> bytes  0.. 7
    //     lane 1 -> bytes  8..15
    //     lane 2 -> bytes 16..23
    //     lane 3 -> bytes 24..31
    //
    // Bytes inside each 64-bit lane are serialized from LSB to MSB.
    // ====================================================================

    function automatic logic [DIGEST_BITS-1:0] serialize_digest(
        input state_t s
    );

        logic [DIGEST_BITS-1:0] result;

        begin

            result = '0;

            for (int i = 0; i < (DIGEST_BITS / 8); i++) begin

                result[i*8 +: 8] =
                    s[i/8][0][(i%8)*8 +: 8];

            end

            return result;

        end

    endfunction


    // ====================================================================
    // CONTROL FSM
    // ====================================================================

    typedef enum logic [2:0] {
        SHA3_CTRL_IDLE         = 3'b000,
        SHA3_CTRL_KECCAK_START = 3'b001,
        SHA3_CTRL_KECCAK_WAIT  = 3'b010,
        SHA3_CTRL_DONE         = 3'b011
    } ctrl_state_e;

    ctrl_state_e ctrl_state;


    // ====================================================================
    // STATUS OUTPUTS
    // ====================================================================

    assign busy =
        (ctrl_state == SHA3_CTRL_KECCAK_START) ||
        (ctrl_state == SHA3_CTRL_KECCAK_WAIT);

    assign done =
        (ctrl_state == SHA3_CTRL_DONE);

    assign keccak_start =
        (ctrl_state == SHA3_CTRL_KECCAK_START);


    // ====================================================================
    // MAIN FSM
    // ====================================================================

    always_ff @(posedge clk) begin

        if (!rst_n) begin

            // ------------------------------------------------------------
            // Explicit state reset.
            // ------------------------------------------------------------

            for (int x = 0; x < STATE_DIM; x++) begin

                for (int y = 0; y < STATE_DIM; y++) begin

                    state_reg[x][y] <= '0;

                end

            end

            digest     <= '0;
            ctrl_state <= SHA3_CTRL_IDLE;

        end

        else begin

            case (ctrl_state)

                // ========================================================
                // IDLE
                // ========================================================

                SHA3_CTRL_IDLE: begin

                    if (start) begin

                        // ------------------------------------------------
                        // Capture the absorbed block.
                        //
                        // The external inputs must remain stable until
                        // this clock edge.
                        // ------------------------------------------------

                        state_reg <= padded_state;

                        ctrl_state <=
                            SHA3_CTRL_KECCAK_START;

                    end

                end


                // ========================================================
                // START KECCAK
                // ========================================================

                SHA3_CTRL_KECCAK_START: begin

                    ctrl_state <=
                        SHA3_CTRL_KECCAK_WAIT;

                end


                // ========================================================
                // WAIT FOR KECCAK
                // ========================================================

                SHA3_CTRL_KECCAK_WAIT: begin

                    if (keccak_done) begin

                        // ------------------------------------------------
                        // Preserve permutation result.
                        // ------------------------------------------------

                        state_reg <= permuted_state;


                        // ------------------------------------------------
                        // Final block:
                        // produce SHA3-256 digest.
                        // ------------------------------------------------

                        if (is_final) begin

                            digest <=
                                serialize_digest(permuted_state);

                            ctrl_state <=
                                SHA3_CTRL_DONE;

                        end

                        // ------------------------------------------------
                        // Non-final block:
                        // retain state and accept another block.
                        // ------------------------------------------------

                        else begin

                            ctrl_state <=
                                SHA3_CTRL_IDLE;

                        end

                    end

                end


                // ========================================================
                // DONE
                // ========================================================

                SHA3_CTRL_DONE: begin

                    // ----------------------------------------------------
                    // done is asserted for exactly one cycle.
                    //
                    // Clear internal sponge state before returning to
                    // IDLE. The digest itself remains available.
                    // ----------------------------------------------------

                    for (int x = 0; x < STATE_DIM; x++) begin

                        for (int y = 0; y < STATE_DIM; y++) begin

                            state_reg[x][y] <= '0;

                        end

                    end

                    ctrl_state <=
                        SHA3_CTRL_IDLE;

                end


                // ========================================================
                // ILLEGAL STATE RECOVERY
                // ========================================================

                default: begin

                    for (int x = 0; x < STATE_DIM; x++) begin

                        for (int y = 0; y < STATE_DIM; y++) begin

                            state_reg[x][y] <= '0;

                        end

                    end

                    digest     <= '0;
                    ctrl_state <= SHA3_CTRL_IDLE;

                end

            endcase

        end

    end

endmodule