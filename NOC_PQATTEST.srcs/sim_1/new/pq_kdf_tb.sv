`timescale 1ns/1ps
//=============================================================================
// File   : pq_kdf_tb.sv
// Module : pq_kdf_tb          <-- module name MATCHES the file name
//
// PQ-Attest Stage 5 gate. Self-contained: no file I/O, no $fscanf, no absolute
// paths. Six golden vectors from software/kmac128_ref.py derive_tile_key().
//
//-----------------------------------------------------------------------------
// BYTE ORDER - read this before changing any literal
//
// pq_kdf packs byte i at [i*8 +: 8]  (byte 0 at the LSB end).
// The Python reference and kdf_vectors.txt print byte 0 LEFTMOST.
//
// The expected values below are therefore stored ALREADY BYTE-REVERSED, with
// the printed form in a comment beside each one. The compare is a direct ===,
// so there is NO byte swap in the pass/fail path and no swap bug can fake a
// failure. bswap256 is used ONLY to print the printed-order value on a
// mismatch, so the log can be diffed against the Python output.
//
//-----------------------------------------------------------------------------
// STYLE RULES THIS FILE FOLLOWS (each one cost real debugging time)
//   - every sized literal on ONE line. A short 'h literal zero-extends
//     silently instead of erroring.
//   - $sformatf, never {string_var, "literal"} - xvlog rejects that.
//   - no part-select on a function call, no member select on a cast.
//   - no hierarchical reference into the DUT. Black box only.
//=============================================================================

module pq_kdf_tb;

    import pq_kdf_pkg::*;

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    logic                         start;
    logic [ROOT_SECRET_BITS-1:0]  root_secret;
    logic [TILE_ID_BITS-1:0]      tile_id;       // 56 bits
    logic [EPOCH_BITS-1:0]        epoch;         // 80 bits
    logic [CONTEXT_MAX_BITS-1:0]  context_in;    // 112 bits
    logic [CONTEXT_LEN_BITS-1:0]  context_len;
    logic [1:0]                   key_len_sel;

    logic [KDF_KEY_MAX_BITS-1:0]  derived_key;
    logic [5:0]                   derived_key_bytes;
    logic                         busy;
    logic                         done;

    pq_kdf dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .root_secret       (root_secret),
        .tile_id           (tile_id),
        .epoch             (epoch),
        .context_in        (context_in),
        .context_len       (context_len),
        .key_len_sel       (key_len_sel),
        .derived_key       (derived_key),
        .derived_key_bytes (derived_key_bytes),
        .busy              (busy),
        .done              (done)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    //-------------------------------------------------------------------------
    // Counters
    //-------------------------------------------------------------------------
    integer checks;
    integer errors;

    task automatic chk(input logic cond, input string what);
        begin
            checks = checks + 1;
            if (cond === 1'b1) begin
                $display("[PASS] %s", what);
            end
            else begin
                errors = errors + 1;
                $display("[FAIL] %s", what);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Display helper: RTL order -> printed order. NOT in the pass/fail path.
    //-------------------------------------------------------------------------
    function automatic logic [255:0] bswap256(input logic [255:0] x);
        logic [255:0] y;
        begin
            y = 256'd0;
            for (int i = 0; i < 32; i = i + 1) begin
                y[(31-i)*8 +: 8] = x[i*8 +: 8];
            end
            bswap256 = y;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Inputs, in RTL order (byte 0 at the LSB end)
    //-------------------------------------------------------------------------
    localparam logic [255:0] ROOT_SECRET_RTL = 256'h1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100;

    localparam logic [55:0]  TILE_01 = 56'h31305f454c4954;
    localparam logic [55:0]  TILE_02 = 56'h32305f454c4954;

    localparam logic [79:0]  EPOCH_1 = 80'h313030305f48434f5045;
    localparam logic [79:0]  EPOCH_2 = 80'h323030305f48434f5045;

    localparam logic [111:0] CTX_KDF  = 112'h0046444b2d5453455454412d5150;
    localparam logic [111:0] CTX_AUTH = 112'h485455412d5453455454412d5150;
    localparam logic [111:0] CTX_NONE = 112'h0;

    //-------------------------------------------------------------------------
    // Expected keys, RTL order. Printed form in the comment.
    //-------------------------------------------------------------------------
    // printed 9c699e785af03e632e2da3cbe9ede27c
    localparam logic [255:0] V01 = 256'h000000000000000000000000000000007ce2ede9cba32d2e633ef05a789e699c;
    // printed f30ddb5b98f18616cfd5869f773fe53a
    localparam logic [255:0] V02 = 256'h000000000000000000000000000000003ae53f779f86d5cf1686f1985bdb0df3;
    // printed 6b166b7c1e131c6b418ee284cd674677
    localparam logic [255:0] V03 = 256'h00000000000000000000000000000000774667cd84e28e416b1c131e7c6b166b;
    // printed ff09225456dd309555bd6bd4a890b279
    localparam logic [255:0] V04 = 256'h0000000000000000000000000000000079b290a8d46bbd559530dd56542209ff;
    // printed 92aea90b633ab5b0f512e4115ad2b4c1
    localparam logic [255:0] V05 = 256'h00000000000000000000000000000000c1b4d25a11e412f5b0b53a630ba9ae92;
    // printed f3d22e09c5b0ba3b0e5a7c85ab7703fc95d5e5dd5bebd9044a3dd2a4824d6989
    localparam logic [255:0] V06 = 256'h89694d82a4d23d4a04d9eb5bdde5d595fc0377ab857c5a0e3bbab0c5092ed2f3;

    //-------------------------------------------------------------------------
    // Byte-order self test.
    //
    // Hand-computed anchor: "TILE_01" prints as 54 49 4c 45 5f 30 31. In RTL
    // order byte 0 (0x54) is at [7:0], so bswap of the RTL value must give the
    // printed value back. An identity bswap FAILS this. A round trip alone
    // would not - the identity round-trips too.
    //-------------------------------------------------------------------------
    task automatic bswap_selftest;
        logic [255:0] wide;
        logic [255:0] swapped;
        begin
            $display("");
            $display("--- byte-order self test ---");

            wide    = {200'd0, TILE_01};
            swapped = bswap256(wide);

            chk(swapped[255:200] === 56'h54494c455f3031,
                "bswap256 anchor: RTL TILE_01 prints as 54494c455f3031");

            chk(bswap256(bswap256(V06)) === V06,
                "bswap256 round trip over 32 bytes");
        end
    endtask

    //-------------------------------------------------------------------------
    // Reset
    //-------------------------------------------------------------------------
    task automatic reset_dut;
        begin
            start       = 1'b0;
            root_secret = 256'd0;
            tile_id     = 56'd0;
            epoch       = 80'd0;
            context_in  = 112'd0;
            context_len = 4'd0;
            key_len_sel = KDF_LEN_128;

            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;

            chk(busy        === 1'b0,   "reset: busy = 0");
            chk(done        === 1'b0,   "reset: done = 0");
            chk(derived_key === 256'd0, "reset: derived_key = 0");
        end
    endtask

    //-------------------------------------------------------------------------
    // One derivation
    //-------------------------------------------------------------------------
    task automatic run_kdf(
        input string        name,
        input logic [55:0]  tile,
        input logic [79:0]  ep,
        input logic [111:0] ctx,
        input integer       ctx_len,
        input logic [1:0]   len_sel,
        input logic [255:0] expect_rtl
    );
        integer cycles;
        logic   key_ok;
        logic   timed_out;
        begin
            key_ok    = 1'b0;
            timed_out = 1'b0;

            while (busy === 1'b1) @(posedge clk);

            @(negedge clk);
            root_secret = ROOT_SECRET_RTL;
            tile_id     = tile;
            epoch       = ep;
            context_in  = ctx;
            context_len = ctx_len[CONTEXT_LEN_BITS-1:0];
            key_len_sel = len_sel;
            start       = 1'b1;

            @(posedge clk);            // request latched on this edge
            @(negedge clk);
            start = 1'b0;

            // Bounded wait. KMAC128 over a 37-byte message is 3 permutations.
            // TSETTLE: sample AFTER the non-blocking updates land. Reading
            // `done` in the active region right after @(posedge clk) returns
            // the value from BEFORE the edge, so the loop exits one cycle
            // late - by which time done has already gone low again.
            cycles = 0;
            while ((done !== 1'b1) && (cycles < 2000)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end

            if (done !== 1'b1) begin
                timed_out = 1'b1;
                chk(1'b0, $sformatf("%s : done asserted within 2000 cycles", name));
            end

            if (timed_out === 1'b0) begin

                if (len_sel === KDF_LEN_256) begin
                    key_ok = (derived_key === expect_rtl);
                    chk(key_ok, $sformatf("%s : 256-bit key", name));
                    chk(derived_key_bytes === 6'd32,
                        $sformatf("%s : derived_key_bytes = 32", name));
                end
                else begin
                    key_ok = (derived_key[127:0] === expect_rtl[127:0]);
                    chk(key_ok, $sformatf("%s : 128-bit key", name));
                    // pq_kdf zero-extends an L=128 key. Stale upper bits left
                    // from a previous 256-bit derivation would be a key leak.
                    chk(derived_key[255:128] === 128'd0,
                        $sformatf("%s : upper 128 bits cleared", name));
                    chk(derived_key_bytes === 6'd16,
                        $sformatf("%s : derived_key_bytes = 16", name));
                end

                if (key_ok !== 1'b1) begin
                    $display("    expected (printed) = %064h", bswap256(expect_rtl));
                    $display("    got      (printed) = %064h", bswap256(derived_key));
                end

                @(posedge clk);
                #1;
                chk(done === 1'b0, $sformatf("%s : done is a one-cycle pulse", name));
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Protocol: a start pulse while busy must be ignored, not queued
    //-------------------------------------------------------------------------
    task automatic start_while_busy_test;
        integer cycles;
        begin
            $display("");
            $display("--- protocol: start while busy ---");

            while (busy === 1'b1) @(posedge clk);

            @(negedge clk);
            root_secret = ROOT_SECRET_RTL;
            tile_id     = TILE_01;
            epoch       = EPOCH_1;
            context_in  = CTX_KDF;
            context_len = 4'd13;
            key_len_sel = KDF_LEN_128;
            start       = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;

            @(posedge clk);
            while (busy !== 1'b1) @(posedge clk);

            // Hit start again with garbage on the inputs. If the DUT latches
            // it, the derived key changes and this test fails.
            @(negedge clk);
            tile_id     = {56{1'b1}};
            context_len = 4'd1;
            start       = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;

            cycles = 0;
            while ((done !== 1'b1) && (cycles < 2000)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end

            // Split into two checks. Conflating them meant a timing miss on
            // `done` reported as "start while busy was not ignored", which is
            // a completely different defect.
            chk(done === 1'b1,
                "start while busy : operation still completed");
            chk(derived_key[127:0] === V01[127:0],
                "start while busy : second request was NOT latched");

            if (derived_key[127:0] !== V01[127:0]) begin
                $display("    expected (printed) = %064h", bswap256(V01));
                $display("    got      (printed) = %064h", bswap256(derived_key));
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Negative control - the checker MUST be able to fail.
    //-------------------------------------------------------------------------
    task automatic negative_control;
        integer errors_before;
        logic [255:0] corrupt;
        begin
            $display("");
            $display("--- negative control ---");

            errors_before = errors;
            corrupt       = V01 ^ 256'd1;      // one bit flipped

            run_kdf("NEG_CTRL (expected to fail)",
                    TILE_01, EPOCH_1, CTX_KDF, 13, KDF_LEN_128, corrupt);

            if (errors > errors_before) begin
                errors = errors_before;        // roll back the deliberate fail
                checks = checks + 1;
                $display("[PASS] negative control detected a one-bit corruption");
            end
            else begin
                checks = checks + 1;
                errors = errors_before + 1;
                $display("[FAIL] negative control did NOT fail - checker is blind");
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // MAIN
    //-------------------------------------------------------------------------
    initial begin : main
        checks = 0;
        errors = 0;

        $display("");
        $display("================================================");
        $display("  PQ-ATTEST STAGE 5 - TILE KEY KDF");
        $display("================================================");

        reset_dut();
        bswap_selftest();

        if (errors != 0) begin
            $display("");
            $display("Byte-order self test FAILED - stopping.");
            $display("No vector result is meaningful until this passes.");
            $display("******** STAGE 5 FAIL ********");
            $finish;
        end

        $display("");
        $display("--- golden vectors ---");
        run_kdf("V01 baseline",       TILE_01, EPOCH_1, CTX_KDF,  13, KDF_LEN_128, V01);
        run_kdf("V02 tile change",    TILE_02, EPOCH_1, CTX_KDF,  13, KDF_LEN_128, V02);
        run_kdf("V03 epoch change",   TILE_01, EPOCH_2, CTX_KDF,  13, KDF_LEN_128, V03);
        run_kdf("V04 context change", TILE_01, EPOCH_1, CTX_AUTH, 14, KDF_LEN_128, V04);
        run_kdf("V05 empty context",  TILE_01, EPOCH_1, CTX_NONE,  0, KDF_LEN_128, V05);
        run_kdf("V06 256-bit key",    TILE_01, EPOCH_1, CTX_KDF,  13, KDF_LEN_256, V06);

        start_while_busy_test();
        negative_control();

        $display("");
        $display("================================================");
        $display("              STAGE 5 KDF TB");
        $display("================================================");
        $display("CHECKS : %0d", checks);
        $display("ERRORS : %0d", errors);
        $display("");

        if (errors == 0) begin
            $display("******** STAGE 5 PASS ********");
            $display("");
            $display("V01 baseline            : PASS");
            $display("V02 tile separation     : PASS");
            $display("V03 epoch separation    : PASS");
            $display("V04 context separation  : PASS");
            $display("V05 empty context       : PASS");
            $display("V06 256-bit key         : PASS");
            $display("Byte-order self test    : PASS");
            $display("Start while busy        : PASS");
            $display("Negative control        : PASS");
            $display("ZERO TEST ERRORS");
        end
        else begin
            $display("******** STAGE 5 FAIL ********");
            $display("DO NOT MARK STAGE 5 COMPLETE");
        end
        $display("================================================");
        $finish;
    end

    //-------------------------------------------------------------------------
    // Global watchdog
    //-------------------------------------------------------------------------
    initial begin : watchdog
        #500000;
        $display("[FAIL] GLOBAL TIMEOUT - simulation did not finish");
        $finish;
    end

endmodule
