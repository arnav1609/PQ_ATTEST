`timescale 1ns/1ps
//=============================================================================
// File   : pq_measurement_tb.sv
// Module : pq_measurement_tb        PQ-Attest Stage 6 gate
//
// Six golden vectors from software/measurement_ref.py, regenerated and
// cross-checked against hashlib.sha3_256.
//
//   M = SHA3-256( TILE_ID || CONFIG || IMEM )
//
//-----------------------------------------------------------------------------
// BYTE ORDER
//   Expected values are stored in RTL order (byte i at [i*8 +: 8]), with the
//   printed form in a comment beside each. The compare is a direct ===, so no
//   swap sits in the pass/fail path and a swap bug cannot fake a failure.
//   bswap256 is used ONLY to print the printed-order value on a mismatch, and
//   is self-tested against a hand-computed anchor before any vector runs.
//
//-----------------------------------------------------------------------------
// STYLE RULES (each one cost real debugging time in this project)
//   - widths come from pq_measurement_pkg; the DUT has no parameters
//   - every sized literal on ONE line; a short 'h literal zero-extends silently
//   - $sformatf, never {string_var, "literal"}
//   - TSETTLE: #1 after every @(posedge clk) before sampling
//=============================================================================

module pq_measurement_tb;

    import pq_measurement_pkg::*;

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic start;

    logic [TILE_ID_BITS-1:0]     tile_id;
    logic [CONFIG_MAX_BITS-1:0]  config_data;
    logic [CONFIG_LEN_BITS-1:0]  config_len;
    logic [IMEM_MAX_BITS-1:0]    imem;
    logic [IMEM_LEN_BITS-1:0]    imem_len;

    logic [MEASUREMENT_BITS-1:0] measurement;
    logic                        busy;
    logic                        done;

    pq_measurement dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .tile_id     (tile_id),
        .config_data (config_data),
        .config_len  (config_len),
        .imem        (imem),
        .imem_len    (imem_len),
        .measurement (measurement),
        .busy        (busy),
        .done        (done)
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
    // RTL order -> printed order. DISPLAY ONLY, never in the compare path.
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
    // TILE_ID values, RTL order (byte 0 at the LSB end)
    //-------------------------------------------------------------------------
    localparam logic [55:0] TILE_01 = 56'h31305f454c4954;   // "TILE_01"
    localparam logic [55:0] TILE_02 = 56'h32305f454c4954;   // "TILE_02"

    //-------------------------------------------------------------------------
    // Golden measurements, RTL order. Printed form in the comment.
    //-------------------------------------------------------------------------
    // printed 959b61960366c705b889e2c09ffaead296e296475f32a610732ab9eac293182a
    localparam logic [255:0] M01 = 256'h2a1893c2eab92a7310a6325f4796e296d2eafa9fc0e289b805c7660396619b95;
    // printed 9bf582fc515b6d0374cc87e11acb4b7b87a2817d4277d4edfd13f0dce0087eb1
    localparam logic [255:0] M02 = 256'hb17e08e0dcf013fdedd477427d81a2877b4bcb1ae187cc74036d5b51fc82f59b;
    // printed e84eb6399f40be93bed1a6c568cc809e9c5cf5f29c678577835cc47de0cf82ce
    localparam logic [255:0] M03 = 256'hce82cfe07dc45c837785679cf2f55c9c9e80cc68c5a6d1be93be409f39b64ee8;
    // printed 79ae0f4b4c397b133ded75229590698f3c36ef9fcf42b4df14be84a9acca07d1
    localparam logic [255:0] M04 = 256'hd107caaca984be14dfb442cf9fef363c8f6990952275ed3d137b394c4b0fae79;
    // printed 82db4e8176bf298b992adc8cdff4c2b862a126a2b0fe0fb5de67b0dc0add158f
    localparam logic [255:0] M05 = 256'h8f15dd0adcb067deb50ffeb0a226a162b8c2f4df8cdc2a998b29bf76814edb82;
    // printed 7203a9f91c00c1caf7d509a9e90c6b538a644c4aabcfc8ef4a21bb6a0c706b02
    localparam logic [255:0] M06 = 256'h026b700c6abb214aefc8cfab4a4c648a536b0ce9a909d5f7cac1001cf9a90372;

    //-------------------------------------------------------------------------
    // Byte-order self test.
    //
    // Hand anchor: "TILE_01" prints as 54 49 4c 45 5f 30 31, so bswap of the
    // RTL value must give that back. An IDENTITY bswap fails this; a round
    // trip alone would NOT, because the identity round-trips too.
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

            chk(bswap256(bswap256(M06)) === M06,
                "bswap256 round trip over 32 bytes");
        end
    endtask

    //-------------------------------------------------------------------------
    // Input loaders
    //-------------------------------------------------------------------------
    task automatic clear_inputs;
        begin
            tile_id     = '0;
            config_data = '0;
            config_len  = '0;
            imem        = '0;
            imem_len    = '0;
        end
    endtask

    // V01 : TILE_01, CONFIG = 00..0f, IMEM = 10..1f    (39 bytes)
    task automatic load_v01;
        begin
            clear_inputs();
            tile_id    = TILE_01;
            config_len = 16;
            imem_len   = 16;
            for (int i = 0; i < 16; i = i + 1) begin
                config_data[i*8 +: 8] = i;
                imem[i*8 +: 8]        = 8'h10 + i;
            end
        end
    endtask

    // V02 : TILE_02, same CONFIG/IMEM as V01           (39 bytes)
    task automatic load_v02;
        begin
            load_v01();
            tile_id = TILE_02;
        end
    endtask

    // V03 : CONFIG = ff 00 01 .. 0e                    (39 bytes)
    task automatic load_v03;
        begin
            load_v01();
            config_data[0*8 +: 8] = 8'hff;
            for (int i = 1; i < 16; i = i + 1) begin
                config_data[i*8 +: 8] = i - 1;
            end
        end
    endtask

    // V04 : IMEM = ff 11 12 .. 1f                      (39 bytes)
    task automatic load_v04;
        begin
            load_v01();
            imem[0*8 +: 8] = 8'hff;
            for (int i = 1; i < 16; i = i + 1) begin
                imem[i*8 +: 8] = 8'h10 + i;
            end
        end
    endtask

    // V05 : empty CONFIG and IMEM. Message is 7 bytes.
    task automatic load_v05;
        begin
            clear_inputs();
            tile_id    = TILE_01;
            config_len = 0;
            imem_len   = 0;
        end
    endtask

    // V06 : CONFIG = 00..3f, IMEM = 40..7f
    //       Total 7+64+64 = 135 bytes = RATE_BYTES - 1. The boundary.
    task automatic load_v06;
        begin
            clear_inputs();
            tile_id    = TILE_01;
            config_len = 64;
            imem_len   = 64;
            for (int i = 0; i < 64; i = i + 1) begin
                config_data[i*8 +: 8] = i;
                imem[i*8 +: 8]        = 8'h40 + i;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Drive and wait
    //-------------------------------------------------------------------------
    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(posedge clk);          // request latched on this edge
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // TSETTLE: sample AFTER the non-blocking updates land. Reading `done` in
    // the active region right after @(posedge clk) returns the PRE-edge value,
    // so the loop exits one cycle late - by which time done has gone low.
    task automatic wait_done(output logic ok);
        integer cycles;
        begin
            cycles = 0;
            while ((done !== 1'b1) && (cycles < 5000)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            ok = (done === 1'b1);
            if (ok !== 1'b1) begin
                $display("    TIMEOUT after %0d cycles", cycles);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Run one vector. Inputs must already be loaded.
    //-------------------------------------------------------------------------
    task automatic run_vector(
        input string        name,
        input logic [255:0] expect_rtl
    );
        logic ok;
        logic m_ok;
        begin
            while (busy === 1'b1) @(posedge clk);

            pulse_start();

            #1;
            chk(busy === 1'b1, $sformatf("%s : busy asserted", name));

            wait_done(ok);

            if (ok !== 1'b1) begin
                chk(1'b0, $sformatf("%s : done asserted", name));
            end
            else begin
                m_ok = (measurement === expect_rtl);
                chk(m_ok, $sformatf("%s : measurement", name));

                if (m_ok !== 1'b1) begin
                    $display("    expected (printed) = %064h", bswap256(expect_rtl));
                    $display("    got      (printed) = %064h", bswap256(measurement));
                end

                @(posedge clk);
                #1;
                chk(done === 1'b0, $sformatf("%s : done is a one-cycle pulse", name));
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Reset
    //-------------------------------------------------------------------------
    task automatic reset_dut;
        begin
            clear_inputs();
            start = 1'b0;
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;

            chk(busy        === 1'b0,   "reset: busy = 0");
            chk(done        === 1'b0,   "reset: done = 0");
            chk(measurement === 256'd0, "reset: measurement = 0");
        end
    endtask

    //-------------------------------------------------------------------------
    // Start while busy.
    //
    // The intruding request carries DIFFERENT inputs, so a latched second
    // start would change the result. Restarting with the same inputs proves
    // nothing - the test would pass either way.
    //-------------------------------------------------------------------------
    task automatic start_while_busy_test;
        logic ok;
        begin
            $display("");
            $display("--- protocol: start while busy ---");

            while (busy === 1'b1) @(posedge clk);

            load_v01();
            pulse_start();

            @(posedge clk);
            #1;
            while (busy !== 1'b1) begin
                @(posedge clk);
                #1;
            end

            // Corrupt the inputs, then hit start again mid-operation.
            @(negedge clk);
            tile_id    = TILE_02;
            config_len = 0;
            imem_len   = 0;
            start      = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;

            wait_done(ok);

            chk(ok, "start while busy : operation still completed");
            chk(measurement === M01,
                "start while busy : second request was NOT latched");

            if (measurement !== M01) begin
                $display("    expected (printed) = %064h", bswap256(M01));
                $display("    got      (printed) = %064h", bswap256(measurement));
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Negative control.
    //
    // One flipped IMEM bit must change the measurement. If it does not, the
    // checker is blind and every PASS above is worthless.
    //-------------------------------------------------------------------------
    task automatic negative_control;
        logic ok;
        begin
            $display("");
            $display("--- negative control ---");

            while (busy === 1'b1) @(posedge clk);

            load_v01();
            imem[0] = ~imem[0];          // flip bit 0 of IMEM byte 0

            pulse_start();
            wait_done(ok);

            chk(ok, "negative control : operation completed");
            chk(measurement !== M01,
                "negative control : 1-bit IMEM change alters the measurement");
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
        $display("  PQ-ATTEST STAGE 6 - TILE MEASUREMENT");
        $display("  M = SHA3-256( TILE_ID || CONFIG || IMEM )");
        $display("================================================");

        reset_dut();
        bswap_selftest();

        if (errors != 0) begin
            $display("");
            $display("Byte-order self test FAILED - stopping.");
            $display("No vector result is meaningful until this passes.");
            $display("******** STAGE 6 FAIL ********");
            $finish;
        end

        $display("");
        $display("--- golden vectors ---");
        load_v01(); run_vector("M01 baseline",       M01);
        load_v02(); run_vector("M02 TILE_ID change", M02);
        load_v03(); run_vector("M03 CONFIG change",  M03);
        load_v04(); run_vector("M04 IMEM change",    M04);
        load_v05(); run_vector("M05 empty CFG/IMEM", M05);
        load_v06(); run_vector("M06 135-byte input", M06);

        $display("");
        $display("--- back to back ---");
        load_v01(); run_vector("B2B A (M01)", M01);
        load_v02(); run_vector("B2B B (M02)", M02);

        start_while_busy_test();
        negative_control();

        $display("");
        $display("================================================");
        $display("           STAGE 6 MEASUREMENT TB");
        $display("================================================");
        $display("CHECKS : %0d", checks);
        $display("ERRORS : %0d", errors);
        $display("");

        if (errors == 0) begin
            $display("******** STAGE 6 PASS ********");
            $display("");
            $display("M01 baseline            : PASS");
            $display("M02 TILE_ID separation  : PASS");
            $display("M03 CONFIG separation   : PASS");
            $display("M04 IMEM separation     : PASS");
            $display("M05 empty CONFIG/IMEM   : PASS");
            $display("M06 135-byte boundary   : PASS");
            $display("Byte-order self test    : PASS");
            $display("Back-to-back            : PASS");
            $display("Start while busy        : PASS");
            $display("Negative control        : PASS");
            $display("ZERO TEST ERRORS");
        end
        else begin
            $display("******** STAGE 6 FAIL ********");
            $display("DO NOT MARK STAGE 6 COMPLETE");
        end
        $display("================================================");
        $finish;
    end

    //-------------------------------------------------------------------------
    // Global watchdog
    //-------------------------------------------------------------------------
    initial begin : watchdog
        #2000000;
        $display("[FAIL] GLOBAL TIMEOUT - simulation did not finish");
        $finish;
    end

endmodule