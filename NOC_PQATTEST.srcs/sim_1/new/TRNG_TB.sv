`timescale 1ns/1ps
module TRNG_CONDITIONER_TB;

    // ============================================================
    // Clock
    // ============================================================

    logic clk;

    always #5 clk = ~clk;


    // ============================================================
    // DUT interface
    // ============================================================

    logic        rst_n;
    logic        abort;

    logic        entropy_valid;
    logic [63:0] entropy_word;
    logic        entropy_last;
    logic        entropy_ready;

    logic [255:0] conditioned_out;
    logic [127:0] nonce_out;

    logic valid;
    logic ready;
    logic busy;


    // ============================================================
    // DUT
    // ============================================================

    trng_conditioner dut (

        .clk (
            clk
        ),

        .rst_n (
            rst_n
        ),

        .abort (
            abort
        ),

        .entropy_valid (
            entropy_valid
        ),

        .entropy_word (
            entropy_word
        ),

        .entropy_last (
            entropy_last
        ),

        .entropy_ready (
            entropy_ready
        ),

        .conditioned_out (
            conditioned_out
        ),

        .nonce_out (
            nonce_out
        ),

        .valid (
            valid
        ),

        .ready (
            ready
        ),

        .busy (
            busy
        )

    );


    // ============================================================
    // Corrected conditioned-output golden vectors
    //
    // These are the Verilog numeric representations corresponding
    // to the Python byte-stream outputs.
    // ============================================================

    localparam logic [255:0] EXPECTED_V1 =
        256'he13bc15cf97d06ce63575fd6aa3123beb79823755166bee5f004162927a35bf5;

    localparam logic [255:0] EXPECTED_V2 =
        256'h47b61f4fbe9b019ca96d0321f64cb8f2808ee3efc9586c6119a85197654fc4d5;

    localparam logic [255:0] EXPECTED_V3 =
        256'haa0b2329eb237f9e7559be6c8af831735bcf1a96301d8efd9aaf967d06a2be62;

    localparam logic [255:0] EXPECTED_V4 =
        256'h7ddb888171e66ccb9ec4ef8372ea0082d1ec6b288304ff443df6583246125234;

    localparam logic [255:0] EXPECTED_V5 =
        256'h7210189bbd681a44a0cc5fc84ff4ec444588051879d54ee693404769a2f7084e;


    // ============================================================
    // Corrected nonce golden vectors
    // ============================================================

    localparam logic [127:0] EXPECTED_N1 =
        128'hb79823755166bee5f004162927a35bf5;

    localparam logic [127:0] EXPECTED_N2 =
        128'h808ee3efc9586c6119a85197654fc4d5;

    localparam logic [127:0] EXPECTED_N3 =
        128'h5bcf1a96301d8efd9aaf967d06a2be62;

    localparam logic [127:0] EXPECTED_N4 =
        128'hd1ec6b288304ff443df6583246125234;

    localparam logic [127:0] EXPECTED_N5 =
        128'h4588051879d54ee693404769a2f7084e;


    // ============================================================
    // Generate test-vector word
    // ============================================================

    function automatic [63:0] make_word;

        input integer vector_id;
        input integer word_id;

        integer i;
        integer byte_num;

        begin

            make_word =
                64'h0000_0000_0000_0000;

            for (i = 0; i < 8; i = i + 1) begin

                byte_num =
                    word_id * 8 + i;

                case (vector_id)

                    // ------------------------------------------------
                    // V1:
                    //
                    // 00 01 02 ... FF
                    // repeated twice
                    // ------------------------------------------------

                    1: begin

                        make_word[i*8 +: 8] =
                            byte_num % 256;

                    end


                    // ------------------------------------------------
                    // V2:
                    //
                    // all zero
                    // ------------------------------------------------

                    2: begin

                        make_word[i*8 +: 8] =
                            8'h00;

                    end


                    // ------------------------------------------------
                    // V3:
                    //
                    // all FF
                    // ------------------------------------------------

                    3: begin

                        make_word[i*8 +: 8] =
                            8'hFF;

                    end


                    // ------------------------------------------------
                    // V4:
                    //
                    // AA 55 AA 55...
                    // ------------------------------------------------

                    4: begin

                        if ((byte_num % 2) == 0)

                            make_word[i*8 +: 8] =
                                8'hAA;

                        else

                            make_word[i*8 +: 8] =
                                8'h55;

                    end


                    // ------------------------------------------------
                    // V5:
                    //
                    // 55 AA 55 AA...
                    // ------------------------------------------------

                    5: begin

                        if ((byte_num % 2) == 0)

                            make_word[i*8 +: 8] =
                                8'h55;

                        else

                            make_word[i*8 +: 8] =
                                8'hAA;

                    end


                    default: begin

                        make_word =
                            64'h0000_0000_0000_0000;

                    end

                endcase

            end

        end

    endfunction


    // ============================================================
    // Reset
    // ============================================================

    task automatic reset_dut;

        begin

            rst_n =
                1'b0;

            abort =
                1'b0;

            entropy_valid =
                1'b0;

            entropy_word =
                64'h0000_0000_0000_0000;

            entropy_last =
                1'b0;

            ready =
                1'b1;

            repeat (4)
                @(posedge clk);

            @(negedge clk);

            rst_n =
                1'b1;

            @(posedge clk);

        end

    endtask


    // ============================================================
    // Send one complete 512-bit entropy vector
    // ============================================================

    task automatic send_vector;

        input integer vector_id;

        integer i;
        integer watchdog;

        begin

            $display("");
            $display(
                "Sending V%0d...",
                vector_id
            );

            for (i = 0; i < 64; i = i + 1) begin

                watchdog =
                    0;


                // ------------------------------------------------
                // Wait for ready
                // ------------------------------------------------

                while (!entropy_ready) begin

                    @(posedge clk);

                    watchdog =
                        watchdog + 1;

                    if (watchdog > 100) begin

                        $display("");
                        $display(
                            "ERROR: timeout waiting for entropy_ready"
                        );

                        $display(
                            "vector           = %0d",
                            vector_id
                        );

                        $display(
                            "word             = %0d",
                            i
                        );

                        $display(
                            "ctrl_state       = %0d",
                            dut.ctrl_state
                        );

                        $display(
                            "total_word_count = %0d",
                            dut.total_word_count
                        );

                        $display(
                            "block_word_count = %0d",
                            dut.block_word_count
                        );

                        $display(
                            "block_index      = %0d",
                            dut.block_index
                        );

                        $display(
                            "busy             = %b",
                            busy
                        );

                        $finish;

                    end

                end


                // ------------------------------------------------
                // Drive data before active clock edge
                // ------------------------------------------------

                @(negedge clk);

                entropy_word =
                    make_word(
                        vector_id,
                        i
                    );

                entropy_valid =
                    1'b1;

                if (i == 63)

                    entropy_last =
                        1'b1;

                else

                    entropy_last =
                        1'b0;


                // ------------------------------------------------
                // Input handshake
                // ------------------------------------------------

                @(posedge clk);


                // ------------------------------------------------
                // Deassert valid
                // ------------------------------------------------

                @(negedge clk);

                entropy_valid =
                    1'b0;

                entropy_last =
                    1'b0;

                entropy_word =
                    64'h0000_0000_0000_0000;

            end


            $display(
                "V%0d: all 64 entropy words accepted.",
                vector_id
            );

        end

    endtask


    // ============================================================
    // Wait for output
    // ============================================================

    task automatic wait_for_output;

        integer watchdog;

        begin

            watchdog =
                0;

            while (!valid) begin

                @(posedge clk);

                watchdog =
                    watchdog + 1;

                if (watchdog > 500) begin

                    $display("");
                    $display(
                        "=============================================="
                    );
                    $display(
                        "ERROR: OUTPUT TIMEOUT"
                    );
                    $display(
                        "=============================================="
                    );

                    $display(
                        "ctrl_state       = %0d",
                        dut.ctrl_state
                    );

                    $display(
                        "total_word_count = %0d",
                        dut.total_word_count
                    );

                    $display(
                        "block_word_count = %0d",
                        dut.block_word_count
                    );

                    $display(
                        "block_index      = %0d",
                        dut.block_index
                    );

                    $display(
                        "entropy_ready    = %b",
                        entropy_ready
                    );

                    $display(
                        "entropy_valid    = %b",
                        entropy_valid
                    );

                    $display(
                        "keccak_start     = %b",
                        dut.keccak_start
                    );

                    $display(
                        "keccak_busy      = %b",
                        dut.keccak_busy
                    );

                    $display(
                        "keccak_done      = %b",
                        dut.keccak_done
                    );

                    $display(
                        "busy             = %b",
                        busy
                    );

                    $display(
                        "valid            = %b",
                        valid
                    );

                    $display(
                        "=============================================="
                    );

                    $finish;

                end

            end

        end

    endtask


    // ============================================================
    // Check output
    // ============================================================

    task automatic check_vector;

        input integer vector_id;

        input [255:0] expected_conditioned;

        input [127:0] expected_nonce;

        begin

            $display("");
            $display(
                "Checking V%0d...",
                vector_id
            );


            // ----------------------------------------------------
            // Conditioned output
            // ----------------------------------------------------

            if (conditioned_out ===
                expected_conditioned) begin

                $display(
                    "PASS: V%0d conditioned output",
                    vector_id
                );

            end

            else begin

                $display(
                    "FAIL: V%0d conditioned output",
                    vector_id
                );

                $display(
                    "Expected: %064h",
                    expected_conditioned
                );

                $display(
                    "Actual  : %064h",
                    conditioned_out
                );

                $finish;

            end


            // ----------------------------------------------------
            // Nonce
            // ----------------------------------------------------

            if (nonce_out ===
                expected_nonce) begin

                $display(
                    "PASS: V%0d nonce",
                    vector_id
                );

            end

            else begin

                $display(
                    "FAIL: V%0d nonce",
                    vector_id
                );

                $display(
                    "Expected: %032h",
                    expected_nonce
                );

                $display(
                    "Actual  : %032h",
                    nonce_out
                );

                $finish;

            end

        end

    endtask


    // ============================================================
    // Permutation counter
    // ============================================================

    integer permutation_count;

    always @(posedge clk) begin

        if (!rst_n) begin

            permutation_count =
                0;

        end

        else if (dut.keccak_done) begin

            permutation_count =
                permutation_count + 1;

            $display(
                "[%0t ns] Keccak permutation %0d complete",
                $time,
                permutation_count
            );

        end

    end


    // ============================================================
    // Main test
    // ============================================================

    initial begin

        clk =
            1'b0;

        rst_n =
            1'b0;

        abort =
            1'b0;

        entropy_valid =
            1'b0;

        entropy_word =
            64'h0000_0000_0000_0000;

        entropy_last =
            1'b0;

        ready =
            1'b1;


        // ========================================================
        // Reset
        // ========================================================

        reset_dut();


        $display("");
        $display(
            "=============================================="
        );
        $display(
            "TRNG CONDITIONER STAGE 4 TEST"
        );
        $display(
            "=============================================="
        );


        // ========================================================
        // V1
        // ========================================================

        permutation_count =
            0;

        send_vector(1);

        wait_for_output();

        check_vector(
            1,
            EXPECTED_V1,
            EXPECTED_N1
        );

        if (permutation_count == 4) begin

            $display(
                "PASS: V1 exactly 4 Keccak permutations"
            );

        end

        else begin

            $display(
                "FAIL: V1 permutation count = %0d",
                permutation_count
            );

            $finish;

        end

        @(posedge clk);


        // ========================================================
        // V2
        // ========================================================

        permutation_count =
            0;

        send_vector(2);

        wait_for_output();

        check_vector(
            2,
            EXPECTED_V2,
            EXPECTED_N2
        );

        if (permutation_count == 4) begin

            $display(
                "PASS: V2 exactly 4 Keccak permutations"
            );

        end

        else begin

            $display(
                "FAIL: V2 permutation count = %0d",
                permutation_count
            );

            $finish;

        end

        @(posedge clk);


        // ========================================================
        // V3
        // ========================================================

        permutation_count =
            0;

        send_vector(3);

        wait_for_output();

        check_vector(
            3,
            EXPECTED_V3,
            EXPECTED_N3
        );

        if (permutation_count == 4) begin

            $display(
                "PASS: V3 exactly 4 Keccak permutations"
            );

        end

        else begin

            $display(
                "FAIL: V3 permutation count = %0d",
                permutation_count
            );

            $finish;

        end

        @(posedge clk);


        // ========================================================
        // V4
        // ========================================================

        permutation_count =
            0;

        send_vector(4);

        wait_for_output();

        check_vector(
            4,
            EXPECTED_V4,
            EXPECTED_N4
        );

        if (permutation_count == 4) begin

            $display(
                "PASS: V4 exactly 4 Keccak permutations"
            );

        end

        else begin

            $display(
                "FAIL: V4 permutation count = %0d",
                permutation_count
            );

            $finish;

        end

        @(posedge clk);


        // ========================================================
        // V5
        // ========================================================

        permutation_count =
            0;

        send_vector(5);

        wait_for_output();

        check_vector(
            5,
            EXPECTED_V5,
            EXPECTED_N5
        );

        if (permutation_count == 4) begin

            $display(
                "PASS: V5 exactly 4 Keccak permutations"
            );

        end

        else begin

            $display(
                "FAIL: V5 permutation count = %0d",
                permutation_count
            );

            $finish;

        end

        @(posedge clk);


        // ========================================================
        // Final result
        // ========================================================

        $display("");
        $display(
            "=============================================="
        );
        $display(
            "ALL TRNG CONDITIONER VECTORS PASS"
        );
        $display(
            "=============================================="
        );


        #20;

        $finish;

    end

endmodule