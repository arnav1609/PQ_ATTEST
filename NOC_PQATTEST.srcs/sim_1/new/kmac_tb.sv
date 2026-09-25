`timescale 1ns/1ps

module KMAC_TB;

    // ============================================================
    // PARAMETERS
    // ============================================================

    localparam int KEY_BYTES    = 32;
    localparam int CUSTOM_BYTES = 16;
    localparam int MSG_BYTES    = 16;
    localparam int TAG_BITS     = 256;

    // ============================================================
    // CLOCK / RESET
    // ============================================================

    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ============================================================
    // DUT INPUTS
    // ============================================================

    logic start;

    logic [KEY_BYTES*8-1:0] key_in;
    logic [$clog2(KEY_BYTES+1)-1:0] key_len;

    logic [CUSTOM_BYTES*8-1:0] custom_in;
    logic [$clog2(CUSTOM_BYTES+1)-1:0] custom_len;

    logic [MSG_BYTES*8-1:0] msg_in;
    logic [$clog2(MSG_BYTES+1)-1:0] msg_len;

    // Output-length select. In KMAC, L is ABSORBED as right_encode(L); it is
    // not a truncation choice. Every KAT in this file is a 256-bit KMAC128,
    // so this must be KMAC_L_256. Leaving it unconnected makes the DUT absorb
    // right_encode(128) = 80 01 (2 bytes) instead of right_encode(256) =
    // 01 00 02 (3 bytes), which shifts the KMAC domain byte and corrupts
    // every tag while leaving the block/permutation count intact.
    logic out_len_sel;

    // ============================================================
    // DUT OUTPUTS
    // ============================================================

    logic [TAG_BITS-1:0] tag_out;
    logic busy;
    logic done;

    // ============================================================
    // DUT
    // ============================================================

    kmac128 #(
        .KEY_BYTES    (KEY_BYTES),
        .CUSTOM_BYTES (CUSTOM_BYTES),
        .MSG_BYTES    (MSG_BYTES)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),

        .start      (start),

        .key_in     (key_in),
        .key_len    (key_len),

        .custom_in  (custom_in),
        .custom_len (custom_len),

        .msg_in     (msg_in),
        .msg_len    (msg_len),

        .out_len_sel (out_len_sel),

        .tag_out    (tag_out),

        .busy       (busy),
        .done        (done)
    );

    // ============================================================
    // TEST COUNTERS
    // ============================================================

    integer passed_tests;
    integer failed_tests;

    // ============================================================
    // CLEAR INPUTS
    // ============================================================

    task automatic clear_inputs;
        begin
            start = 1'b0;

            key_in  = '0;
            key_len = '0;

            custom_in  = '0;
            custom_len = '0;

            msg_in  = '0;
            msg_len = '0;

            out_len_sel = kmac_pkg::KMAC_L_256;
        end
    endtask

    // ============================================================
    // INCREMENTAL KEY
    //
    // 00 01 02 ... 1F
    // ============================================================

    task automatic load_incremental_key(
        input integer length
    );
        begin
            key_in = '0;

            for (int i = 0; i < length; i++) begin
                key_in[i*8 +: 8] = i[7:0];
            end

            key_len = length;
        end
    endtask

    // ============================================================
    // INCREMENTAL CUSTOM
    // ============================================================

    task automatic load_incremental_custom(
        input integer length
    );
        begin
            custom_in = '0;

            for (int i = 0; i < length; i++) begin
                custom_in[i*8 +: 8] = i[7:0];
            end

            custom_len = length;
        end
    endtask

    // ============================================================
    // INCREMENTAL MESSAGE
    // ============================================================

    task automatic load_incremental_msg(
        input integer length
    );
        begin
            msg_in = '0;

            for (int i = 0; i < length; i++) begin
                msg_in[i*8 +: 8] = i[7:0];
            end

            msg_len = length;
        end
    endtask

    // ============================================================
    // START KMAC
    // ============================================================

    task automatic start_kmac;
        begin

            @(posedge clk);

            start <= 1'b1;

            @(posedge clk);

            start <= 1'b0;

        end
    endtask

    // ============================================================
    // WAIT FOR DONE
    // ============================================================

    task automatic wait_done;

        integer timeout;

        begin

            timeout = 0;

            while (!done && timeout < 5000) begin

                @(posedge clk);

                timeout = timeout + 1;

            end

            if (timeout >= 5000) begin

                $display(
                    "ERROR: KMAC operation TIMEOUT"
                );

                failed_tests = failed_tests + 1;

            end

        end

    endtask

    // ============================================================
    // CHECK TAG
    // ============================================================

    task automatic check_tag(
        input logic [TAG_BITS-1:0] expected,
        input string test_name
    );
        begin

            if (tag_out === expected) begin

                $display(
                    "PASS: %s",
                    test_name
                );

                passed_tests = passed_tests + 1;

            end

            else begin

                $display(
                    "FAIL: %s",
                    test_name
                );

                $display(
                    "  EXPECTED = %064h",
                    expected
                );

                $display(
                    "  ACTUAL   = %064h",
                    tag_out
                );

                failed_tests = failed_tests + 1;

            end

        end
    endtask

    // ============================================================
    // FULL KMAC TEST
    // ============================================================

    task automatic run_kmac_test(
        input string test_name,

        input integer klen,
        input integer clen,
        input integer mlen,

        input logic [TAG_BITS-1:0] expected
    );

        begin

            clear_inputs();

            load_incremental_key(klen);
            load_incremental_custom(clen);
            load_incremental_msg(mlen);

            start_kmac();

            wait_done();

            check_tag(
                expected,
                test_name
            );

            // DONE must be one clock only
            @(posedge clk);

            if (done !== 1'b0) begin

                $display(
                    "FAIL: %s - DONE did not return low",
                    test_name
                );

                failed_tests = failed_tests + 1;

            end

        end

    endtask

    // ============================================================
    // RESET TEST
    // ============================================================

    task automatic reset_test;

        begin

            $display("");
            $display("========================================");
            $display("RESET TEST");
            $display("========================================");

            rst_n = 1'b0;

            repeat (4)
                @(posedge clk);

            if (busy !== 1'b0) begin

                $display(
                    "FAIL: reset busy"
                );

                failed_tests = failed_tests + 1;

            end

            else begin

                $display(
                    "PASS: reset busy = 0"
                );

                passed_tests = passed_tests + 1;

            end

            if (done !== 1'b0) begin

                $display(
                    "FAIL: reset done"
                );

                failed_tests = failed_tests + 1;

            end

            else begin

                $display(
                    "PASS: reset done = 0"
                );

                passed_tests = passed_tests + 1;

            end

            rst_n = 1'b1;

            @(posedge clk);

        end

    endtask

    // ============================================================
    // BUSY / START-WHILE-BUSY TEST
    //
    // Same vector as Test 2.
    // ============================================================

    task automatic busy_protocol_test;

        logic [TAG_BITS-1:0] expected;

        begin

            $display("");
            $display("========================================");
            $display("BUSY / START-WHILE-BUSY TEST");
            $display("========================================");

            clear_inputs();

            load_incremental_key(32);
            load_incremental_custom(0);
            load_incremental_msg(16);

            expected =
                256'h350e8bd95e6df79c65878fd953f0369745115da9cb1c7bdce21b4384a56cd119;

            start_kmac();

            wait (busy === 1'b1);

            // Attempt second start while busy
            @(posedge clk);

            start <= 1'b1;

            @(posedge clk);

            start <= 1'b0;

            wait_done();

            check_tag(
                expected,
                "Start while busy ignored"
            );

        end

    endtask

    // ============================================================
    // INTERNAL PERMUTATION COUNT TEST
    //
    // Expected:
    //
    // BLOCK0 -> permutation 1
    // BLOCK1 -> permutation 2
    // BLOCK2 -> permutation 3
    //
    // Exactly 3 Keccak-f[1600] permutations.
    // ============================================================

    task automatic permutation_count_test;

        integer permutation_count;
        integer timeout;

        logic [TAG_BITS-1:0] expected;

        begin

            $display("");
            $display("========================================");
            $display("PERMUTATION COUNT TEST");
            $display("========================================");

            clear_inputs();

            load_incremental_key(32);
            load_incremental_custom(0);
            load_incremental_msg(16);

            expected =
                256'h350e8bd95e6df79c65878fd953f0369745115da9cb1c7bdce21b4384a56cd119;

            permutation_count = 0;
            timeout = 0;

            start_kmac();

            while (!done && timeout < 5000) begin

                @(posedge clk);

                if (dut.keccak_done) begin

                    permutation_count =
                        permutation_count + 1;

                end

                timeout = timeout + 1;

            end

            // ----------------------------------------------------
            // Check permutation count
            // ----------------------------------------------------

            if (permutation_count == 3) begin

                $display(
                    "PASS: exactly 3 Keccak permutations"
                );

                passed_tests = passed_tests + 1;

            end

            else begin

                $display(
                    "FAIL: expected 3 permutations, got %0d",
                    permutation_count
                );

                failed_tests = failed_tests + 1;

            end

            // ----------------------------------------------------
            // Check cryptographic result too
            // ----------------------------------------------------

            check_tag(
                expected,
                "Permutation-count test tag"
            );

        end

    endtask

    // ============================================================
    // MAIN TEST
    // ============================================================

    initial begin

        passed_tests = 0;
        failed_tests = 0;

        clear_inputs();

        rst_n = 1'b0;

        // ========================================================
        // RESET
        // ========================================================

        reset_test();

        // ========================================================
        // KMAC128 KNOWN-ANSWER TESTS
        // ========================================================

        $display("");
        $display("========================================");
        $display("KMAC128 KNOWN-ANSWER TESTS");
        $display("========================================");

        // --------------------------------------------------------
        // TEST 1
        //
        // K = 00 01 ... 1F
        // S = empty
        // X = empty
        // --------------------------------------------------------

        run_kmac_test(
            "KMAC128 / empty message / empty custom",

            32,
            0,
            0,

            256'h973ad9b322481f9e33d9b846afdf832e22857038c98773a9aec45b25a004a502
        );

        // --------------------------------------------------------
        // TEST 2
        //
        // K = 00 01 ... 1F
        // S = empty
        // X = 00 01 ... 0F
        // --------------------------------------------------------

        run_kmac_test(
            "KMAC128 / 16-byte message / empty custom",

            32,
            0,
            16,

            256'h350e8bd95e6df79c65878fd953f0369745115da9cb1c7bdce21b4384a56cd119
        );

        // --------------------------------------------------------
        // TEST 3
        //
        // K = 00 01 ... 1F
        // S = "Custom"
        // X = 00 01 ... 0F
        // --------------------------------------------------------

        clear_inputs();

        load_incremental_key(32);
        load_incremental_msg(16);

        custom_in = '0;

        custom_in[0*8 +: 8] = "C";
        custom_in[1*8 +: 8] = "u";
        custom_in[2*8 +: 8] = "s";
        custom_in[3*8 +: 8] = "t";
        custom_in[4*8 +: 8] = "o";
        custom_in[5*8 +: 8] = "m";

        custom_len = 6;

        start_kmac();

        wait_done();

        check_tag(
            256'h29b7bd43a1df5e4ffbacb9d3134aa837dc3ee504a563858ca2327fe0fef702db,
            "KMAC128 / 16-byte message / Custom"
        );

        // --------------------------------------------------------
        // TEST 4
        //
        // K  = 32 bytes
        // S  = 16 bytes
        // X  = 16 bytes
        // --------------------------------------------------------

        run_kmac_test(
            "KMAC128 / maximum v1 lengths",

            32,
            16,
            16,

            256'h556c806a871cc489e51b2f3085ac01ac55065b94f2b0e43af340c14faa83e13e
        );

        // --------------------------------------------------------
        // TEST 5
        //
        // K = 16 bytes
        // S = empty
        // X = 16 bytes
        // --------------------------------------------------------

        run_kmac_test(
            "KMAC128 / 16-byte key boundary",

            16,
            0,
            16,

            256'hf1501b0abeb872265fc62c77e9a37c59ba8038288bad24b4b6861fc410c659a4
        );

        // --------------------------------------------------------
        // TEST 6  -  L=128 KAT  (out_len_sel LOW)
        //
        // Previously untested in this TB: every test above is L=256, so the
        // out_len_sel-low path - the one S-5 (pq_kdf) and S-7 depend on most -
        // had no known-answer test of its own. Vector independently generated
        // by software/kmac128_ref.py (self-tested against the 3 NIST SP 800-185
        // KMAC128 samples):
        //     K = 00..1F (32),  S = empty,  X = 00..0F (16),  L = 128
        // For L=128 only tag_out[127:0] is the answer (absorbed, not truncated:
        // it is NOT the L=256 tag's low 16 bytes). RTL byte order (byte 0 LSB).
        // --------------------------------------------------------

        clear_inputs();
        load_incremental_key(32);
        load_incremental_custom(0);
        load_incremental_msg(16);
        out_len_sel = kmac_pkg::KMAC_L_128;

        start_kmac();
        wait_done();

        if (tag_out[127:0] === 128'h1f2915cfef11bdfabebf8e536b71fa30) begin
            $display("PASS: KMAC128 / L=128 KAT (out_len_sel low)");
            passed_tests = passed_tests + 1;
        end
        else begin
            $display("FAIL: KMAC128 / L=128 KAT (out_len_sel low)");
            $display("  EXPECTED = %032h", 128'h1f2915cfef11bdfabebf8e536b71fa30);
            $display("  ACTUAL   = %032h", tag_out[127:0]);
            failed_tests = failed_tests + 1;
        end

        // ========================================================
        // PROTOCOL TESTS
        // ========================================================

        busy_protocol_test();

        permutation_count_test();

        // ========================================================
        // FINAL RESULT
        // ========================================================

        $display("");
        $display("================================================");
        $display("              STAGE 3 KMAC128 TB");
        $display("================================================");

        $display(
            "PASSED TESTS : %0d",
            passed_tests
        );

        $display(
            "FAILED TESTS : %0d",
            failed_tests
        );

        if (failed_tests == 0) begin

            $display("");
            $display("******** STAGE 3 PASS ********");
            $display("");

            $display(
                "KMAC128 KATs             : PASS"
            );

            $display(
                "L=128 KAT (out_len low)  : PASS"
            );

            $display(
                "Empty message            : PASS"
            );

            $display(
                "Custom string            : PASS"
            );

            $display(
                "Maximum v1 lengths       : PASS"
            );

            $display(
                "Key boundary             : PASS"
            );

            $display(
                "Busy / Done              : PASS"
            );

            $display(
                "Start while busy         : PASS"
            );

            $display(
                "3 Keccak permutations    : PASS"
            );

            $display(
                "Permutation tag          : PASS"
            );

            $display(
                "ZERO TEST ERRORS"
            );

            $display("");

        end

        else begin

            $display("");
            $display("******** STAGE 3 FAIL ********");
            $display("");
            $display("DO NOT MARK STAGE 3 COMPLETE");
            $display("");

        end

        $finish;

    end

endmodule