`timescale 1ns/1ps

module trng_conditioner
    import keccak_pkg::*;
    import trng_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,

    // ============================================================
    // Security abort
    // ============================================================

    input  logic         abort,


    // ============================================================
    // Raw entropy input
    //
    // Exactly 64 accepted 64-bit words are consumed.
    // ============================================================

    input  logic         entropy_valid,
    input  logic [63:0]  entropy_word,
    input  logic         entropy_last,
    output logic         entropy_ready,


    // ============================================================
    // Conditioned output
    // ============================================================

    output logic [CONDITIONED_BITS-1:0] conditioned_out,
    output logic [NONCE_BITS-1:0]       nonce_out,

    output logic         valid,
    input  logic         ready,

    output logic         busy
);


    // ============================================================
    // Compile-time consistency checks
    // ============================================================

    initial begin

        if ((TOTAL_WORDS % KECCAK_RATE_WORDS) != 0) begin

            $error(
                "trng_conditioner: TOTAL_WORDS must be divisible by KECCAK_RATE_WORDS"
            );

        end

        if (NUM_BLOCKS != 4) begin

            $error(
                "trng_conditioner: v1 requires exactly 4 Keccak blocks"
            );

        end

    end


    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [1:0] {
        S_IDLE    = 2'd0,
        S_ABSORB  = 2'd1,
        S_PERMUTE = 2'd2,
        S_OUTPUT  = 2'd3
    } state_e;

    state_e ctrl_state;


    // ============================================================
    // Keccak state
    // ============================================================

    state_t state_reg;

    state_t first_state;

    state_t absorb_next_state;

    state_t permute_state_reg;

    state_t keccak_state_out;


    // ============================================================
    // Keccak control
    // ============================================================

    logic keccak_start;
    logic keccak_done;
    logic keccak_busy;


    // ============================================================
    // Counters
    //
    // total_word_count:
    //
    //   0..63  = raw entropy
    //   64..67 = padding
    //
    // block_word_count:
    //
    //   0..16 = position inside 17-word rate block
    //
    // block_index:
    //
    //   0..3 = Keccak block number
    // ============================================================

    logic [6:0] total_word_count;

    logic [4:0] block_word_count;

    logic [1:0] block_index;


    // ============================================================
    // Current word
    // ============================================================

    logic [63:0] current_word;

    logic entropy_fire;


    // ============================================================
    // First-word state
    //
    // Start a new transaction from a completely zeroed state.
    // This avoids overlapping NBAs to state_reg.
    // ============================================================

    always_comb begin

        first_state = '{default:'0};

        first_state[0][0] =
            entropy_word;

    end


    // ============================================================
    // Current word generation
    //
    // Raw phase:
    //     words 0..63 come from entropy_word
    //
    // Padding phase:
    //     words 64..67 are generated internally.
    //
    // Python reference:
    //
    //     append(0x01)
    //     zero pad
    //     final byte OR 0x80
    //
    // Because the byte stream is little-endian within each
    // 64-bit Keccak lane:
    //
    //     word 64 = 01 00 00 00 00 00 00 00
    //     word 65 = 00 00 00 00 00 00 00 00
    //     word 66 = 00 00 00 00 00 00 00 00
    //     word 67 = 80 00 00 00 00 00 00 00
    // ============================================================

    always_comb begin

        current_word =
            64'h0000_0000_0000_0000;

        if (total_word_count < RAW_ENTROPY_WORDS) begin

            current_word =
                entropy_word;

        end

        else begin

            case (total_word_count)

                7'd64:
                    current_word =
                        64'h0000_0000_0000_0001;

                7'd65:
                    current_word =
                        64'h0000_0000_0000_0000;

                7'd66:
                    current_word =
                        64'h0000_0000_0000_0000;

                7'd67:
                    current_word =
                        64'h8000_0000_0000_0000;

                default:
                    current_word =
                        64'h0000_0000_0000_0000;

            endcase

        end

    end


    // ============================================================
    // Absorb current 64-bit word
    //
    // Word i maps to:
    //
    //     x = i % 5
    //     y = i / 5
    //
    // exactly matching the Python reference.
    // ============================================================

    always_comb begin

        absorb_next_state =
            state_reg;

        absorb_next_state[
            block_word_count % 5
        ][
            block_word_count / 5
        ] =
            state_reg[
                block_word_count % 5
            ][
                block_word_count / 5
            ]
            ^
            current_word;

    end


    // ============================================================
    // External entropy ready
    //
    // Only raw entropy uses the external handshake.
    //
    // Padding is generated internally.
    // ============================================================

    always_comb begin

        entropy_ready = 1'b0;

        if (!abort) begin

            case (ctrl_state)

                S_IDLE: begin

                    entropy_ready = 1'b1;

                end

                S_ABSORB: begin

                    if (total_word_count <
                        RAW_ENTROPY_WORDS)

                        entropy_ready = 1'b1;

                    else

                        entropy_ready = 1'b0;

                end

                default: begin

                    entropy_ready = 1'b0;

                end

            endcase

        end

    end


    // ============================================================
    // Entropy handshake
    // ============================================================

    assign entropy_fire =
        entropy_valid &&
        entropy_ready;


    // ============================================================
    // Keccak start
    // ============================================================

    assign keccak_start =
        (ctrl_state == S_PERMUTE);


    // ============================================================
    // Keccak-f[1600]
    //
    // Existing Stage-1 module uses active-high synchronous reset.
    //
    // Conditioner uses active-low rst_n.
    // ============================================================

    keccak_f1600 u_keccak (

        .clk         (clk),

        .rst         (~rst_n),

        .start       (keccak_start),

        .state_in    (permute_state_reg),

        .state_out   (keccak_state_out),

        .busy        (keccak_busy),

        .done        (keccak_done),

        .round_valid (),
        .round_index ()

    );


    // ============================================================
    // Main FSM
    // ============================================================

    always_ff @(posedge clk) begin

        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        if (!rst_n) begin

            ctrl_state <=
                S_IDLE;

            state_reg <=
                '{default:'0};

            permute_state_reg <=
                '{default:'0};

            total_word_count <=
                7'd0;

            block_word_count <=
                5'd0;

            block_index <=
                2'd0;

        end


        // --------------------------------------------------------
        // Security abort
        //
        // Synchronously zeroize all sensitive state.
        // --------------------------------------------------------

        else if (abort) begin

            ctrl_state <=
                S_IDLE;

            state_reg <=
                '{default:'0};

            permute_state_reg <=
                '{default:'0};

            total_word_count <=
                7'd0;

            block_word_count <=
                5'd0;

            block_index <=
                2'd0;

        end


        // --------------------------------------------------------
        // Normal operation
        // --------------------------------------------------------

        else begin

            case (ctrl_state)


                // =================================================
                // IDLE
                // =================================================

                S_IDLE: begin

                    if (entropy_fire) begin

                        // Clean initial state + first word.
                        state_reg <=
                            first_state;

                        total_word_count <=
                            7'd1;

                        block_word_count <=
                            5'd1;

                        block_index <=
                            2'd0;

                        ctrl_state <=
                            S_ABSORB;

                    end

                end


                // =================================================
                // ABSORB
                // =================================================

                S_ABSORB: begin


                    // ------------------------------------------------
                    // RAW ENTROPY PHASE
                    // ------------------------------------------------

                    if (total_word_count <
                        RAW_ENTROPY_WORDS) begin

                        if (entropy_fire) begin

                            // Current word completes a 17-word
                            // rate block.

                            if (block_word_count == 5'd16) begin

                                state_reg <=
                                    absorb_next_state;

                                permute_state_reg <=
                                    absorb_next_state;

                                total_word_count <=
                                    total_word_count + 7'd1;

                                block_word_count <=
                                    5'd0;

                                ctrl_state <=
                                    S_PERMUTE;

                            end

                            else begin

                                state_reg <=
                                    absorb_next_state;

                                total_word_count <=
                                    total_word_count + 7'd1;

                                block_word_count <=
                                    block_word_count + 5'd1;

                            end

                        end

                    end


                    // ------------------------------------------------
                    // INTERNAL PADDING PHASE
                    // ------------------------------------------------

                    else begin

                        // Padding words are consumed automatically.
                        //
                        // No entropy_valid is required.
                        // No entropy_ready is required.

                        if (block_word_count == 5'd16) begin

                            // Word 67 completes block 3.

                            state_reg <=
                                absorb_next_state;

                            permute_state_reg <=
                                absorb_next_state;

                            total_word_count <=
                                total_word_count + 7'd1;

                            block_word_count <=
                                5'd0;

                            ctrl_state <=
                                S_PERMUTE;

                        end

                        else begin

                            state_reg <=
                                absorb_next_state;

                            total_word_count <=
                                total_word_count + 7'd1;

                            block_word_count <=
                                block_word_count + 5'd1;

                        end

                    end

                end


                // =================================================
                // KECCAK PERMUTE
                // =================================================

                S_PERMUTE: begin

                    if (keccak_done) begin

                        state_reg <=
                            keccak_state_out;

                        // Exactly four permutations:
                        //
                        // block 0
                        // block 1
                        // block 2
                        // block 3

                        if (block_index == 2'd3) begin

                            ctrl_state <=
                                S_OUTPUT;

                        end

                        else begin

                            block_index <=
                                block_index + 2'd1;

                            ctrl_state <=
                                S_ABSORB;

                        end

                    end

                end


                // =================================================
                // OUTPUT
                // =================================================

                S_OUTPUT: begin

                    if (ready) begin

                        ctrl_state <=
                            S_IDLE;

                    end

                end


                // =================================================
                // Illegal-state recovery
                // =================================================

                default: begin

                    ctrl_state <=
                        S_IDLE;

                    state_reg <=
                        '{default:'0};

                    permute_state_reg <=
                        '{default:'0};

                    total_word_count <=
                        7'd0;

                    block_word_count <=
                        5'd0;

                    block_index <=
                        2'd0;

                end

            endcase

        end

    end


    // ============================================================
    // Conditioned output
    //
    // Python reference:
    //
    //     state[x][y].to_bytes(8, "little")
    //
    // First four rate lanes:
    //
    //     A[0][0]
    //     A[1][0]
    //     A[2][0]
    //     A[3][0]
    //
    // ============================================================

    always_comb begin

        conditioned_out = '0;

        for (int i = 0; i < CONDITIONED_BYTES; i = i + 1) begin

            conditioned_out[i*8 +: 8] =
                state_reg[
                    i/8
                ][
                    0
                ][
                    (i%8)*8 +: 8
                ];

        end

    end


    // ============================================================
    // Nonce
    // ============================================================

    assign nonce_out =
        conditioned_out[NONCE_BITS-1:0];


    // ============================================================
    // Status
    // ============================================================

    assign valid =
        (ctrl_state == S_OUTPUT);

    assign busy =
        (ctrl_state != S_IDLE) &&
        (ctrl_state != S_OUTPUT);

endmodule