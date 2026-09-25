`timescale 1ns/1ps

module TRNG_TOP_TB;

    // ============================================================
    // Clock
    // ============================================================

    logic clk;

    always #5 clk = ~clk;


    // ============================================================
    // DUT inputs
    // ============================================================

    logic        rst_n;

    logic [63:0] entropy_word;
    logic        entropy_valid;
    logic        entropy_last;
    logic        entropy_ready;

    logic        conditioned_ready;


    // ============================================================
    // DUT outputs
    // ============================================================

    logic [255:0] conditioned_out;
    logic [127:0] nonce_out;

    logic conditioned_valid;

    logic busy;
    logic health_ok;
    logic health_fail;
    logic error;


    // ============================================================
    // DUT
    // ============================================================

    trng_top dut (

        .clk (
            clk
        ),

        .rst_n (
            rst_n
        ),

        .entropy_word (
            entropy_word
        ),

        .entropy_valid (
            entropy_valid
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

        .conditioned_valid (
            conditioned_valid
        ),

        .conditioned_ready (
            conditioned_ready
        ),

        .busy (
            busy
        ),

        .health_ok (
            health_ok
        ),

        .health_fail (
            health_fail
        ),

        .error (
            error
        )

    );


    // ============================================================
    // Golden V1 values
    //
    // Already verified by TRNG_CONDITIONER_TB.
    // ============================================================

    localparam logic [255:0] EXPECTED_V1 =
        256'he13bc15cf97d06ce63575fd6aa3123beb79823755166bee5f004162927a35bf5;

    localparam logic [127:0] EXPECTED_N1 =
        128'hb79823755166bee5f004162927a35bf5;


    // ============================================================
    // Test accounting
    // ============================================================

    integer passed_tests;
    integer failed_tests;

    integer x;
    integer y;

    logic state_zero;


    // ============================================================
    // V1 deterministic entropy generator
    //
    // Bytes:
    // 00 01 02 03 ... FF 00 01 ...
    // ============================================================

    function automatic [63:0] make_v1_word;

        input integer word_id;

        integer i;
        integer byte_num;

        begin

            make_v1_word =
                64'h0000_0000_0000_0000;

            for (
                i = 0;
                i < 8;
                i = i + 1
            ) begin

                byte_num =
                    word_id * 8 + i;

                make_v1_word[i*8 +: 8] =
                    byte_num % 256;

            end

        end

    endfunction


    // ============================================================
    // Reset DUT
    // ============================================================

    task automatic reset_dut;

        begin

            rst_n =
                1'b0;

            entropy_valid =
                1'b0;

            entropy_word =
                64'h0000_0000_0000_0000;

            entropy_last =
                1'b0;

            conditioned_ready =
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
    // Send one entropy word
    //
    // Waits for entropy_ready.
    // ============================================================

    task automatic send_word;

        input logic [63:0] word;
        input logic        last;

        begin

            while (!entropy_ready)
                @(posedge clk);

            @(negedge clk);

            entropy_word =
                word;

            entropy_valid =
                1'b1;

            entropy_last =
                last;

            @(posedge clk);

            @(negedge clk);

            entropy_valid =
                1'b0;

            entropy_last =
                1'b0;

            entropy_word =
                64'h0000_0000_0000_0000;

        end

    endtask


    // ============================================================
    // Send healthy V1
    // ============================================================

    task automatic send_v1;

        integer i;

        begin

            $display("");
            $display(
                "Sending healthy V1 entropy..."
            );

            for (
                i = 0;
                i < 64;
                i = i + 1
            ) begin

                send_word(
                    make_v1_word(i),
                    (i == 63)
                );

            end

            $display(
                "V1: all 64 entropy words accepted."
            );

        end

    endtask


    // ============================================================
    // Wait for conditioned output
    // ============================================================

    task automatic wait_for_valid;

        integer watchdog;

        begin

            watchdog =
                0;

            while (!conditioned_valid) begin

                @(posedge clk);

                watchdog =
                    watchdog + 1;

                if (watchdog > 1000) begin

                    $display("");
                    $display(
                        "ERROR: timeout waiting for conditioned_valid"
                    );

                    $display(
                        "ctrl_state       = %0d",
                        dut.u_conditioner.ctrl_state
                    );

                    $display(
                        "total_word_count = %0d",
                        dut.u_conditioner.total_word_count
                    );

                    $display(
                        "block_word_count = %0d",
                        dut.u_conditioner.block_word_count
                    );

                    $display(
                        "block_index      = %0d",
                        dut.u_conditioner.block_index
                    );

                    $display(
                        "health_fail      = %b",
                        health_fail
                    );

                    $display(
                        "busy             = %b",
                        busy
                    );

                    $finish;

                end

            end

        end

    endtask


    // ============================================================
    // TEST 1
    // Reset state
    // ============================================================

    task automatic test_reset;

        begin

            $display("");
            $display(
                "TEST 1: Reset state"
            );


            if (
                health_ok &&
                !health_fail &&
                !error
            ) begin

                $display(
                    "PASS: health status clean after reset"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: unexpected reset health state"
                );

                $display(
                    "health_ok   = %b",
                    health_ok
                );

                $display(
                    "health_fail = %b",
                    health_fail
                );

                $display(
                    "error       = %b",
                    error
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (
                !conditioned_valid &&
                !busy
            ) begin

                $display(
                    "PASS: conditioner idle after reset"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: conditioner not idle after reset"
                );

                failed_tests =
                    failed_tests + 1;

            end

        end

    endtask


    // ============================================================
    // TEST 2
    // Healthy operation
    // ============================================================

    task automatic test_healthy_operation;

        begin

            $display("");
            $display(
                "TEST 2: Healthy entropy operation"
            );

            send_v1();

            wait_for_valid();


            if (
                conditioned_out ===
                EXPECTED_V1
            ) begin

                $display(
                    "PASS: conditioned output matches V1"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: conditioned output mismatch"
                );

                $display(
                    "Expected = %064h",
                    EXPECTED_V1
                );

                $display(
                    "Actual   = %064h",
                    conditioned_out
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (
                nonce_out ===
                EXPECTED_N1
            ) begin

                $display(
                    "PASS: nonce matches V1"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: nonce mismatch"
                );

                $display(
                    "Expected = %032h",
                    EXPECTED_N1
                );

                $display(
                    "Actual   = %032h",
                    nonce_out
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (
                health_ok &&
                !health_fail &&
                !error
            ) begin

                $display(
                    "PASS: health remains OK"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: unexpected health failure"
                );

                failed_tests =
                    failed_tests + 1;

            end


            @(posedge clk);

        end

    endtask


    // ============================================================
    // TEST 3
    // Health-test failure
    //
    // Send repeated zero words until health_fail occurs.
    //
    // IMPORTANT:
    // We do NOT blindly send 40 words because once health_fail
    // asserts, the conditioner drives entropy_ready low.
    // ============================================================

    task automatic test_health_failure;

        integer i;

        begin

            $display("");
            $display(
                "TEST 3: Health-test failure"
            );


            while (!entropy_ready)
                @(posedge clk);


            for (
                i = 0;
                i < 40;
                i = i + 1
            ) begin

                if (health_fail)
                    i = 40;

                else
                    send_word(
                        64'h0000_0000_0000_0000,
                        1'b0
                    );

            end


            // Allow the registered health failure to propagate.

            @(posedge clk);


            if (health_fail) begin

                $display(
                    "PASS: health_fail asserted"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: health_fail did not assert"
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (error) begin

                $display(
                    "PASS: error asserted with health failure"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: error did not follow health failure"
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (!health_ok) begin

                $display(
                    "PASS: health_ok deasserted"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: health_ok remained asserted"
                );

                failed_tests =
                    failed_tests + 1;

            end

        end

    endtask


    // ============================================================
    // TEST 4
    // Abort and zeroization
    // ============================================================

    task automatic test_abort_zeroization;

        begin

            $display("");
            $display(
                "TEST 4: Abort and zeroization"
            );


            // Allow conditioner abort to execute.

            @(posedge clk);


            if (
                dut.u_conditioner.ctrl_state ==
                2'd0
            ) begin

                $display(
                    "PASS: conditioner returned to IDLE"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: conditioner did not return to IDLE"
                );

                $display(
                    "ctrl_state = %0d",
                    dut.u_conditioner.ctrl_state
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (
                dut.u_conditioner.total_word_count == 0 &&
                dut.u_conditioner.block_word_count == 0 &&
                dut.u_conditioner.block_index == 0
            ) begin

                $display(
                    "PASS: conditioner counters zeroized"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: conditioner counters not zeroized"
                );

                $display(
                    "total_word_count = %0d",
                    dut.u_conditioner.total_word_count
                );

                $display(
                    "block_word_count = %0d",
                    dut.u_conditioner.block_word_count
                );

                $display(
                    "block_index = %0d",
                    dut.u_conditioner.block_index
                );

                failed_tests =
                    failed_tests + 1;

            end


            // ----------------------------------------------------
            // Check every Keccak state lane individually.
            // This avoids the unsupported:
            //
            // state_reg === '{default:'0}
            //
            // construct that caused the previous XSim crash.
            // ----------------------------------------------------

            state_zero =
                1'b1;

            for (
                x = 0;
                x < 5;
                x = x + 1
            ) begin

                for (
                    y = 0;
                    y < 5;
                    y = y + 1
                ) begin

                    if (
                        dut.u_conditioner.state_reg[x][y] !==
                        64'h0000_0000_0000_0000
                    ) begin

                        state_zero =
                            1'b0;

                    end

                end

            end


            if (state_zero) begin

                $display(
                    "PASS: conditioner state zeroized"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: conditioner state not zeroized"
                );

                failed_tests =
                    failed_tests + 1;

            end

        end

    endtask


    // ============================================================
    // TEST 5
    // No conditioned output after health failure
    // ============================================================

    task automatic test_no_output_after_failure;

        begin

            $display("");
            $display(
                "TEST 5: No output after health failure"
            );


            if (!conditioned_valid) begin

                $display(
                    "PASS: no conditioned output after failure"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: conditioned_valid asserted after failure"
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (!busy) begin

                $display(
                    "PASS: conditioner is not busy after abort"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: conditioner remains busy"
                );

                failed_tests =
                    failed_tests + 1;

            end

        end

    endtask


    // ============================================================
    // TEST 6
    // Sticky health failure
    // ============================================================

    task automatic test_failure_sticky;

        begin

            $display("");
            $display(
                "TEST 6: Sticky health failure"
            );


            repeat (5)
                @(posedge clk);


            if (
                health_fail &&
                !health_ok &&
                error
            ) begin

                $display(
                    "PASS: health failure remains sticky"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: health failure not sticky"
                );

                failed_tests =
                    failed_tests + 1;

            end

        end

    endtask


    // ============================================================
    // TEST 7
    // Reset recovery
    // ============================================================

    task automatic test_reset_recovery;

        begin

            $display("");
            $display(
                "TEST 7: Reset recovery"
            );


            reset_dut();


            if (
                health_ok &&
                !health_fail &&
                !error
            ) begin

                $display(
                    "PASS: health recovered after reset"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: health did not recover after reset"
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (
                !busy &&
                !conditioned_valid
            ) begin

                $display(
                    "PASS: conditioner recovered to idle"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: conditioner not idle after recovery"
                );

                failed_tests =
                    failed_tests + 1;

            end

        end

    endtask


    // ============================================================
    // TEST 8
    // Output backpressure
    // ============================================================

    task automatic test_backpressure;

        begin

            $display("");
            $display(
                "TEST 8: Output backpressure"
            );


            // Generate another healthy result.

            send_v1();

            wait_for_valid();


            // Stop the consumer.

            conditioned_ready =
                1'b0;


            repeat (5)
                @(posedge clk);


            if (conditioned_valid) begin

                $display(
                    "PASS: valid held while ready=0"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: valid dropped while ready=0"
                );

                failed_tests =
                    failed_tests + 1;

            end


            if (
                conditioned_out ===
                EXPECTED_V1
            ) begin

                $display(
                    "PASS: output held during backpressure"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: output changed during backpressure"
                );

                failed_tests =
                    failed_tests + 1;

            end


            // Release consumer.

            conditioned_ready =
                1'b1;


            @(posedge clk);


            if (!conditioned_valid) begin

                $display(
                    "PASS: valid cleared after handshake"
                );

                passed_tests =
                    passed_tests + 1;

            end
            else begin

                $display(
                    "FAIL: valid remained asserted after handshake"
                );

                failed_tests =
                    failed_tests + 1;

            end

        end

    endtask


    // ============================================================
    // MAIN
    // ============================================================

    initial begin

        clk =
            1'b0;

        rst_n =
            1'b0;

        entropy_word =
            64'h0000_0000_0000_0000;

        entropy_valid =
            1'b0;

        entropy_last =
            1'b0;

        conditioned_ready =
            1'b1;

        passed_tests =
            0;

        failed_tests =
            0;

        state_zero =
            1'b0;


        // --------------------------------------------------------
        // Initial reset
        // --------------------------------------------------------

        reset_dut();


        // --------------------------------------------------------
        // TEST 1
        // --------------------------------------------------------

        test_reset();


        // --------------------------------------------------------
        // TEST 2
        // --------------------------------------------------------

        test_healthy_operation();


        // --------------------------------------------------------
        // TEST 3
        // --------------------------------------------------------

        test_health_failure();


        // --------------------------------------------------------
        // TEST 4
        // --------------------------------------------------------

        test_abort_zeroization();


        // --------------------------------------------------------
        // TEST 5
        // --------------------------------------------------------

        test_no_output_after_failure();


        // --------------------------------------------------------
        // TEST 6
        // --------------------------------------------------------

        test_failure_sticky();


        // --------------------------------------------------------
        // TEST 7
        // --------------------------------------------------------

        test_reset_recovery();


        // --------------------------------------------------------
        // TEST 8
        // --------------------------------------------------------

        test_backpressure();


        // --------------------------------------------------------
        // FINAL REPORT
        // --------------------------------------------------------

        $display("");
        $display(
            "=================================================="
        );

        $display(
            "TRNG TOP-LEVEL STAGE 4 VERIFICATION"
        );

        $display(
            "=================================================="
        );

        $display(
            "PASSED TESTS = %0d",
            passed_tests
        );

        $display(
            "FAILED TESTS = %0d",
            failed_tests
        );


        if (failed_tests == 0) begin

            $display("");
            $display(
                "******** STAGE 4 TOP-LEVEL PASS ********"
            );

        end
        else begin

            $display("");
            $display(
                "******** STAGE 4 TOP-LEVEL FAIL ********"
            );

        end


        $display(
            "=================================================="
        );


        #100;

        $finish;

    end

endmodule