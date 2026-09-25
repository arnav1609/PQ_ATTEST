`timescale 1ns/1ps

module tb_sha3_256;

    import keccak_pkg::*;
    import sha3_pkg::*;


    // ====================================================================
    // CLOCK
    // ====================================================================

    logic clk;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end


    // ====================================================================
    // DUT INTERFACE
    // ====================================================================

    logic                             rst_n;
    logic                             start;
    logic [RATE_BITS-1:0]             msg_block_in;
    logic [$clog2(RATE_BYTES+1)-1:0]  valid_bytes;
    logic                             is_final;

    logic [DIGEST_BITS-1:0]           digest;
    logic                             busy;
    logic                             done;


    // ====================================================================
    // DUT
    // ====================================================================

    sha3_256 dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .msg_block_in (msg_block_in),
        .valid_bytes  (valid_bytes),
        .is_final     (is_final),
        .digest       (digest),
        .busy         (busy),
        .done         (done)
    );


    // ====================================================================
    // TEST COUNTERS
    // ====================================================================

    integer passed_tests;
    integer failed_tests;


    // ====================================================================
    // GOLDEN DIGESTS
    //
    // These are packed according to the project convention:
    //
    //     digest[i*8 +: 8] = byte i
    //
    // Therefore they are byte-reversed relative to the conventional
    // SHA3 hexadecimal display.
    // ====================================================================

    localparam logic [255:0] SHA3_EMPTY =
        256'h4a43f8804b0ad882fa493be44dff80f562d661a05647c15166d71ebff8c6ffa7;

    localparam logic [255:0] SHA3_ABC =
        256'h3215431145e2bf465b529d3e6e085f85bd90d36b2d175c04b225e24fa75d983a;

    localparam logic [255:0] SHA3_HELLO_WORLD =
        256'h38394ef2fb3b1ca394fd72d9a1fb71caf322769ec8aa9909047343567ecc4b64;

    localparam logic [255:0] SHA3_135_A =
        256'hc9432839138953929c1dcc3e46d29636c3a1f94704c3b7671efb4cc453bb9480;

    localparam logic [255:0] SHA3_136_A =
        256'he15e69c2dcefa470a56fc6818d52115ec22bbded91300a3a458edb149f55c53f;

    localparam logic [255:0] SHA3_137_A =
        256'h1486734e34951fc9b11f39d7ee99d724f75af99e87c515dffaccd2ed6c84d6f8;


    // ====================================================================
    // RESET
    // ====================================================================

    task automatic reset_dut;

        begin

            rst_n        = 1'b0;
            start        = 1'b0;
            msg_block_in = '0;
            valid_bytes  = '0;
            is_final     = 1'b0;

            repeat (3) begin
                @(posedge clk);
                #1;
            end

            if (busy !== 1'b0) begin
                $display("[FAIL] reset: busy != 0");
                failed_tests++;
            end
            else begin
                $display("[PASS] reset: busy = 0");
                passed_tests++;
            end

            if (done !== 1'b0) begin
                $display("[FAIL] reset: done != 0");
                failed_tests++;
            end
            else begin
                $display("[PASS] reset: done = 0");
                passed_tests++;
            end

            if (digest !== '0) begin
                $display(
                    "[FAIL] reset: digest != 0, got %064h",
                    digest
                );
                failed_tests++;
            end
            else begin
                $display("[PASS] reset: digest = 0");
                passed_tests++;
            end

            rst_n = 1'b1;

            @(posedge clk);
            #1;

        end

    endtask


    // ====================================================================
    // CHECK DIGEST
    // ====================================================================

    task automatic check_digest(
        input logic [255:0] expected,
        input string        name
    );

        begin

            if (digest === expected) begin

                $display(
                    "[PASS] %s",
                    name
                );

                $display(
                    "       DIGEST = %064h",
                    digest
                );

                passed_tests++;

            end
            else begin

                $display(
                    "[FAIL] %s",
                    name
                );

                $display(
                    "       EXPECTED = %064h",
                    expected
                );

                $display(
                    "       GOT      = %064h",
                    digest
                );

                failed_tests++;

            end

        end

    endtask


    // ====================================================================
    // WAIT FOR DONE
    // ====================================================================

    task automatic wait_for_done(
        output logic completed
    );

        integer timeout;

        begin

            completed = 1'b0;
            timeout   = 0;

            while (done !== 1'b1) begin

                @(posedge clk);
                #1;

                timeout++;

                if (timeout >= 1000) begin

                    $display(
                        "[FAIL] TIMEOUT: done not asserted"
                    );

                    failed_tests++;

                    return;

                end

            end

            completed = 1'b1;

        end

    endtask


    // ====================================================================
    // WAIT FOR IDLE
    // ====================================================================

    task automatic wait_for_idle(
        output logic completed
    );

        integer timeout;

        begin

            completed = 1'b0;
            timeout   = 0;

            while (busy !== 1'b0) begin

                @(posedge clk);
                #1;

                timeout++;

                if (timeout >= 1000) begin

                    $display(
                        "[FAIL] TIMEOUT: busy did not deassert"
                    );

                    failed_tests++;

                    return;

                end

            end

            completed = 1'b1;

        end

    endtask


    // ====================================================================
    // CHECK DONE/BUSY
    // ====================================================================

    task automatic check_done_pulse;

        begin

            if (done !== 1'b1) begin
                $display("[FAIL] done != 1");
                failed_tests++;
            end
            else begin
                $display("[PASS] done = 1 with valid digest");
                passed_tests++;
            end

            if (busy !== 1'b0) begin
                $display("[FAIL] busy != 0 when done");
                failed_tests++;
            end
            else begin
                $display("[PASS] done -> busy = 0");
                passed_tests++;
            end

            @(posedge clk);
            #1;

            if (done !== 1'b0) begin
                $display("[FAIL] done is not one-cycle");
                failed_tests++;
            end
            else begin
                $display("[PASS] done is one-cycle pulse");
                passed_tests++;
            end

        end

    endtask


    // ====================================================================
    // RUN ONE FINAL BLOCK
    // ====================================================================

    task automatic run_final_block(
        input logic [RATE_BITS-1:0] block_data,
        input integer               nbytes,
        output logic                completed
    );

        begin

            completed = 1'b0;

            @(negedge clk);
            #1;

            msg_block_in = block_data;
            valid_bytes  = nbytes;
            is_final     = 1'b1;
            start        = 1'b1;

            @(posedge clk);
            #1;

            start = 1'b0;

            wait_for_done(completed);

        end

    endtask


    // ====================================================================
    // EMPTY
    // ====================================================================

    task automatic test_empty;

        logic [RATE_BITS-1:0] block;
        logic completed;

        begin

            block = '0;

            run_final_block(
                block,
                0,
                completed
            );

            if (!completed)
                return;

            check_digest(
                SHA3_EMPTY,
                "SHA3-256 empty"
            );

            check_done_pulse();

        end

    endtask


    // ====================================================================
    // ABC
    // ====================================================================

    task automatic test_abc;

        logic [RATE_BITS-1:0] block;
        logic completed;

        begin

            block = '0;

            block[7:0]  = 8'h61;
            block[15:8] = 8'h62;
            block[23:16] = 8'h63;

            run_final_block(
                block,
                3,
                completed
            );

            if (!completed)
                return;

            check_digest(
                SHA3_ABC,
                "SHA3-256 abc"
            );

            check_done_pulse();

        end

    endtask


    // ====================================================================
    // HELLO WORLD
    // ====================================================================

    task automatic test_hello_world;

        logic [RATE_BITS-1:0] block;
        logic completed;

        begin

            block = '0;

            block[0*8 +: 8]  = 8'h68;
            block[1*8 +: 8]  = 8'h65;
            block[2*8 +: 8]  = 8'h6c;
            block[3*8 +: 8]  = 8'h6c;
            block[4*8 +: 8]  = 8'h6f;
            block[5*8 +: 8]  = 8'h20;
            block[6*8 +: 8]  = 8'h77;
            block[7*8 +: 8]  = 8'h6f;
            block[8*8 +: 8]  = 8'h72;
            block[9*8 +: 8]  = 8'h6c;
            block[10*8 +: 8] = 8'h64;

            run_final_block(
                block,
                11,
                completed
            );

            if (!completed)
                return;

            check_digest(
                SHA3_HELLO_WORLD,
                "SHA3-256 hello world"
            );

            check_done_pulse();

        end

    endtask


    // ====================================================================
    // 135 BYTES
    // ====================================================================

    task automatic test_135_bytes;

        logic [RATE_BITS-1:0] block;
        logic completed;

        begin

            block = '0;

            for (int i = 0; i < 135; i++) begin
                block[i*8 +: 8] = 8'h61;
            end

            run_final_block(
                block,
                135,
                completed
            );

            if (!completed)
                return;

            check_digest(
                SHA3_135_A,
                "SHA3-256 135-byte a"
            );

            check_done_pulse();

        end

    endtask


    // ====================================================================
    // 136 BYTES
    // ====================================================================

    task automatic test_136_bytes;

        logic [RATE_BITS-1:0] block;
        logic completed;

        begin

            block = '0;

            for (int i = 0; i < 136; i++) begin
                block[i*8 +: 8] = 8'h61;
            end

            // First block is non-final.
            @(negedge clk);
            #1;

            msg_block_in = block;
            valid_bytes  = 136;
            is_final     = 1'b0;
            start        = 1'b1;

            @(posedge clk);
            #1;

            start = 1'b0;

            wait_for_idle(completed);

            if (!completed)
                return;

            if (done !== 1'b0) begin
                $display(
                    "[FAIL] 136-byte non-final block asserted done"
                );
                failed_tests++;
            end
            else begin
                $display(
                    "[PASS] 136-byte non-final block has no done"
                );
                passed_tests++;
            end

            // Second block is empty and final.
            block = '0;

            @(negedge clk);
            #1;

            msg_block_in = block;
            valid_bytes  = 0;
            is_final     = 1'b1;
            start        = 1'b1;

            @(posedge clk);
            #1;

            start = 1'b0;

            wait_for_done(completed);

            if (!completed)
                return;

            check_digest(
                SHA3_136_A,
                "SHA3-256 136-byte a"
            );

            check_done_pulse();

        end

    endtask


    // ====================================================================
    // 137 BYTES
    // ====================================================================

    task automatic test_137_bytes;

        logic [RATE_BITS-1:0] block;
        logic completed;

        begin

            block = '0;

            for (int i = 0; i < 136; i++) begin
                block[i*8 +: 8] = 8'h61;
            end

            // First block.
            @(negedge clk);
            #1;

            msg_block_in = block;
            valid_bytes  = 136;
            is_final     = 1'b0;
            start        = 1'b1;

            @(posedge clk);
            #1;

            start = 1'b0;

            wait_for_idle(completed);

            if (!completed)
                return;

            if (done !== 1'b0) begin
                $display(
                    "[FAIL] 137-byte block 0 asserted done"
                );
                failed_tests++;
            end
            else begin
                $display(
                    "[PASS] 137-byte block 0 has no done"
                );
                passed_tests++;
            end

            // Second block: one byte, final.
            block = '0;
            block[7:0] = 8'h61;

            @(negedge clk);
            #1;

            msg_block_in = block;
            valid_bytes  = 1;
            is_final     = 1'b1;
            start        = 1'b1;

            @(posedge clk);
            #1;

            start = 1'b0;

            wait_for_done(completed);

            if (!completed)
                return;

            check_digest(
                SHA3_137_A,
                "SHA3-256 137-byte a"
            );

            check_done_pulse();

        end

    endtask


    // ====================================================================
    // PADDING: EMPTY
    // ====================================================================

    task automatic test_padding_empty;

        begin

            @(negedge clk);
            #1;

            msg_block_in = '0;
            valid_bytes  = 0;
            is_final     = 1'b1;
            start        = 1'b0;

            #1;

            if (dut.padded_block[7:0] !== 8'h06) begin

                $display(
                    "[FAIL] empty padding domain = %02h",
                    dut.padded_block[7:0]
                );

                failed_tests++;

            end
            else begin

                $display(
                    "[PASS] empty padding domain = 06"
                );

                passed_tests++;

            end

            if (dut.padded_block[1087] !== 1'b1) begin

                $display(
                    "[FAIL] empty padding final bit != 1"
                );

                failed_tests++;

            end
            else begin

                $display(
                    "[PASS] empty padding final bit = 1"
                );

                passed_tests++;

            end

        end

    endtask


    // ====================================================================
    // PADDING: 135 BYTES
    // ====================================================================

    task automatic test_padding_135;

        logic [RATE_BITS-1:0] block;

        begin

            block = '0;

            for (int i = 0; i < 135; i++) begin
                block[i*8 +: 8] = 8'h61;
            end

            @(negedge clk);
            #1;

            msg_block_in = block;
            valid_bytes  = 135;
            is_final     = 1'b1;
            start        = 1'b0;

            #1;

            if (dut.padded_block[135*8 +: 8] !== 8'h86) begin

                $display(
                    "[FAIL] 135-byte padding byte != 86, got %02h",
                    dut.padded_block[135*8 +: 8]
                );

                failed_tests++;

            end
            else begin

                $display(
                    "[PASS] 135-byte padding byte = 86"
                );

                passed_tests++;

            end

        end

    endtask


    // ====================================================================
    // PADDING: NON-FINAL 136 BYTES
    // ====================================================================

    task automatic test_nonfinal_136_padding;

        logic [RATE_BITS-1:0] block;

        begin

            block = '0;

            for (int i = 0; i < 136; i++) begin
                block[i*8 +: 8] = 8'h61;
            end

            @(negedge clk);
            #1;

            msg_block_in = block;
            valid_bytes  = 136;
            is_final     = 1'b0;
            start        = 1'b0;

            #1;

            if (dut.padded_block !== block) begin

                $display(
                    "[FAIL] non-final 136-byte block modified"
                );

                failed_tests++;

            end
            else begin

                $display(
                    "[PASS] non-final 136-byte block unchanged"
                );

                passed_tests++;

            end

        end

    endtask


    // ====================================================================
    // START WHILE BUSY
    // ====================================================================

    task automatic test_start_while_busy;

        logic [RATE_BITS-1:0] block;
        logic completed;

        begin

            // Start ABC.
            block = '0;
            block[7:0]   = 8'h61;
            block[15:8]  = 8'h62;
            block[23:16] = 8'h63;

            @(negedge clk);
            #1;

            msg_block_in = block;
            valid_bytes  = 3;
            is_final     = 1'b1;
            start        = 1'b1;

            @(posedge clk);
            #1;

            start = 1'b0;

            if (busy !== 1'b1) begin

                $display(
                    "[FAIL] busy not asserted after start"
                );

                failed_tests++;

            end
            else begin

                $display(
                    "[PASS] busy asserted after start"
                );

                passed_tests++;

            end

            // Attempt a second transaction while busy.
            block = '0;
            block[7:0] = 8'hff;

            @(negedge clk);
            #1;

            msg_block_in = block;
            valid_bytes  = 1;
            is_final     = 1'b1;
            start        = 1'b1;

            @(posedge clk);
            #1;

            start = 1'b0;

            wait_for_done(completed);

            if (!completed)
                return;

            check_digest(
                SHA3_ABC,
                "start while busy ignored"
            );

            check_done_pulse();

        end

    endtask


    // ====================================================================
    // NEGATIVE CONTROL
    //
    // Hash "abd", then verify it does NOT equal SHA3("abc").
    //
    // This is a functional negative test.
    // It is NOT the formal mutation test.
    // ====================================================================

    task automatic test_negative_control;

        logic [RATE_BITS-1:0] block;
        logic completed;

        begin

            block = '0;

            block[7:0]   = 8'h61;
            block[15:8]  = 8'h62;
            block[23:16] = 8'h64;

            run_final_block(
                block,
                3,
                completed
            );

            if (!completed)
                return;

            if (digest === SHA3_ABC) begin

                $display(
                    "[FAIL] negative control: abd matched abc"
                );

                failed_tests++;

            end
            else begin

                $display(
                    "[PASS] negative control: abd != abc"
                );

                passed_tests++;

            end

            check_done_pulse();

        end

    endtask


    // ====================================================================
    // BACK-TO-BACK
    // ====================================================================

    task automatic test_back_to_back;

        begin

            test_abc();

            test_empty();

            test_abc();

        end

    endtask


    // ====================================================================
    // MAIN
    // ====================================================================

    initial begin

        passed_tests = 0;
        failed_tests = 0;

        rst_n        = 1'b0;
        start        = 1'b0;
        msg_block_in = '0;
        valid_bytes  = '0;
        is_final     = 1'b0;


        // ---------------------------------------------------------------
        // RESET
        // ---------------------------------------------------------------

        reset_dut();


        // ---------------------------------------------------------------
        // PADDING
        // ---------------------------------------------------------------

        test_padding_empty();

        test_padding_135();

        test_nonfinal_136_padding();


        // ---------------------------------------------------------------
        // BASIC KATs
        // ---------------------------------------------------------------

        test_empty();

        test_abc();

        test_hello_world();

        test_135_bytes();


        // ---------------------------------------------------------------
        // MULTI-BLOCK BOUNDARIES
        // ---------------------------------------------------------------

        test_136_bytes();

        test_137_bytes();


        // ---------------------------------------------------------------
        // PROTOCOL
        // ---------------------------------------------------------------

        test_start_while_busy();


        // ---------------------------------------------------------------
        // NEGATIVE CONTROL
        // ---------------------------------------------------------------

        test_negative_control();


        // ---------------------------------------------------------------
        // STATE ISOLATION
        // ---------------------------------------------------------------

        test_back_to_back();


        // ---------------------------------------------------------------
        // SUMMARY
        // ---------------------------------------------------------------

        $display("");
        $display("============================================================");
        $display("              SHA3-256 TEST SUMMARY");
        $display("============================================================");

        $display(
            "TOTAL CHECKS : %0d",
            passed_tests + failed_tests
        );

        $display(
            "PASSED       : %0d",
            passed_tests
        );

        $display(
            "FAILED       : %0d",
            failed_tests
        );

        $display("============================================================");


        if (failed_tests == 0) begin

            $display("");
            $display("============================================================");
            $display("                SHA3-256 : PASS");
            $display("============================================================");
            $display("Byte order       : LSB-first");
            $display("KATs             : PASS");
            $display("Padding          : PASS");
            $display("135-byte         : PASS");
            $display("136-byte         : PASS");
            $display("137-byte         : PASS");
            $display("Busy handling    : PASS");
            $display("Negative control : PASS");
            $display("Back-to-back     : PASS");
            $display("============================================================");

        end
        else begin

            $display("");
            $display("============================================================");
            $display("                SHA3-256 : FAIL");
            $display("============================================================");
            $display("DO NOT proceed to Stage 6.");
            $display("============================================================");

        end

        $finish;

    end

endmodule