//=============================================================================
// PQ-Attest  -  Stage 7  -  pq_attestation_tag_tb
//
// GOLDEN VECTOR PROVENANCE
//   All eight tags were COMPUTED by a from-scratch Keccak-f[1600] +
//   SP 800-185 reference, self-tested first against the three published NIST
//   KMAC128 sample vectors:
//     1  E5780B0D3EA6F7D3A429C5706AA43A00FADBD7D49628839E3187243F456EE14E
//     2  3B1FBA963CD8B0B59E8C1A6D71888B7143651AF8BA0A7070C0979E2811324AA5
//     3  1F5B4E6CCA02209E0DCB5CA635B89A15E271ECC760071DFD805FAA38F9729230
//   All three reproduced exactly. These vectors are not hand-copied and are
//   not the DUT restated.
//
// STYLE MATCHES pq_measurement_tb / pq_kdf_tb
//   forever #5 clock, chk(input logic, input string), $sformatf for names,
//   global watchdog with $display + $finish, expected values in RTL order
//   with the printed form in a comment ABOVE the literal.
//
// TSETTLE DISCIPLINE
//   Drive at negedge. Inside every wait loop: @(posedge clk) THEN #1. Reading
//   immediately after the edge returns the PRE-edge value, silently missing a
//   one-cycle pulse and exiting the loop a cycle late.
//
// PROTOCOL UNDER TEST  (kmac128 / pq_measurement convention)
//   busy LOW on the done cycle; done a one-cycle registered pulse; err pulses
//   with done only on a rejected request.
//
// Target : xc7a100tcsg324-1, Vivado 2024.1
//=============================================================================

`timescale 1ns/1ps

module pq_attestation_tag_tb;

    import pq_attest_pkg::*;

    //-------------------------------------------------------------------------
    // Clock
    //-------------------------------------------------------------------------
    logic clk;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    logic rst_n;
    logic start;

    logic [TILE_KEY_BITS-1:0]    tile_key;
    logic [TILE_ID_BITS-1:0]     tile_id;
    logic [EPOCH_BITS-1:0]       epoch;
    logic [NONCE_BITS-1:0]       nonce;
    logic [MEASUREMENT_BITS-1:0] measurement;
    logic [1:0]                  tag_len_sel;

    logic [TAG_MAX_BITS-1:0]     tag;
    logic [5:0]                  tag_bytes;
    logic                        busy;
    logic                        done;
    logic                        err;

    pq_attestation_tag dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .tile_key    (tile_key),
        .tile_id     (tile_id),
        .epoch       (epoch),
        .nonce       (nonce),
        .measurement (measurement),
        .tag_len_sel (tag_len_sel),
        .tag         (tag),
        .tag_bytes   (tag_bytes),
        .busy        (busy),
        .done        (done),
        .err         (err)
    );

    //-------------------------------------------------------------------------
    // Scoreboard
    //-------------------------------------------------------------------------
    integer checks;
    integer errors;

    task automatic chk(input logic cond, input string what);
        begin
            checks = checks + 1;
            if (cond === 1'b1) $display("[PASS] %s", what);
            else begin
                errors = errors + 1;
                $display("[FAIL] %s", what);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Byte swap - DISPLAY ONLY. Never on the pass/fail path.
    //-------------------------------------------------------------------------
    function automatic logic [255:0] bswap256(input logic [255:0] v);
        logic [255:0] r;
        begin
            r = '0;
            for (int i = 0; i < 32; i++)
                r[(31-i)*8 +: 8] = v[i*8 +: 8];
            return r;
        end
    endfunction

    //-------------------------------------------------------------------------
    // INPUT VECTORS   (RTL order: byte 0 at the LSB end)
    // TILE_01 / EPOCH_1 transcribed from pq_kdf_tb.sv:112,115 on disk.
    //-------------------------------------------------------------------------
    localparam logic [55:0]  TILE_01  = 56'h31305f454c4954;   // "TILE_01"
    localparam logic [55:0]  TILE_MUT = 56'h31305f454c4955;   // byte0 'T'->0x55

    localparam logic [79:0]  EPOCH_1  = 80'h313030305f48434f5045; // "EPOCH_0001"
    localparam logic [79:0]  EPOCH_M  = 80'h303030305f48434f5045; // "EPOCH_0000"

    // 00 01 02 ... 0f   (byte 0 = 0x00)
    localparam logic [127:0] NONCE_A  = 128'h0f0e0d0c0b0a09080706050403020100;
    localparam logic [127:0] NONCE_M  = 128'h0e0e0d0c0b0a09080706050403020100;

    // Stage 6 golden measurement M01 (pq_measurement_tb.sv:110), used here as
    // an opaque 32-byte input.
    localparam logic [255:0] MEAS_M01 =
        256'h2a1893c2eab92a7310a6325f4796e296d2eafa9fc0e289b805c7660396619b95;
    localparam logic [255:0] MEAS_MUT =
        256'h2a1893c2eab92a7310a6325f4796e296d2eafa9fc0e289b805c7660396619b94;

    // Explicit 32-byte test key 00..1f. In the integrated SoC this comes from
    // pq_kdf.derived_key in 256-bit mode; it is an explicit constant here so
    // Stage 7 stays independently testable without Stage 5 in the build.
    localparam logic [255:0] KEY_T =
        256'h1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100;
    localparam logic [255:0] KEY_MUT =
        256'h1e1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100;

    //-------------------------------------------------------------------------
    // GOLDEN TAGS - RTL order. Printed form in the comment ABOVE the literal,
    // matching the convention in pq_measurement_tb.sv.
    //-------------------------------------------------------------------------
    // printed 491c8ce777d0bf3577aa4fe87ec587ddf4da0e81a4df90e5b803e6641145600d
    localparam logic [255:0] V01 =
        256'h0d60451164e603b8e590dfa4810edaf4dd87c57ee84faa7735bfd077e78c1c49;

    // printed a7e665a930a394088765177b6739f43db657a672bc8e7f197dac6e18fdc1e494
    localparam logic [255:0] V02 =
        256'h94e4c1fd186eac7d197f8ebc72a657b63df439677b1765870894a330a965e6a7;

    // printed 36e32c8f13889da2f94b5be48650d55cc7cdc6f145f9b02447b8b7ad3205c763
    localparam logic [255:0] V03 =
        256'h63c70532adb7b84724b0f945f1c6cdc75cd55086e45b4bf9a29d88138f2ce336;

    // printed d89f3d5ab172d94045ac36392d273c69f3a20265d7225bfcb03313ee00269141
    localparam logic [255:0] V04 =
        256'h41912600ee1333b0fc5b22d76502a2f3693c272d3936ac4540d972b15a3d9fd8;

    // printed ec85835dcf0017ab2df88ef35e07956b64f59312c99371d19ca8d600b3803ca3
    localparam logic [255:0] V05 =
        256'ha33c80b300d6a89cd17193c91293f5646b95075ef38ef82dab1700cf5d8385ec;

    // printed cd751ae4b6d193185a75641d376e8061ec5dac94c9486ad9c51e343ee85f441f
    localparam logic [255:0] V06 =
        256'h1f445fe83e341ec5d96a48c994ac5dec61806e371d64755a1893d1b6e41a75cd;

    // printed dabd282cc70b742effb22ca5188d393d
    // INDEPENDENTLY COMPUTED. Not V01[127:0].
    localparam logic [127:0] V07 =
        128'h3d398d18a52cb2ff2e740bc72c28bdda;

    // printed 7cbc7c9e31ed3febc2ce55bd5e5c34cb1c3022861ba741fb21c617bd6ba1b1b4
    // The tag this DUT would emit if custom_len were left at 0.
    localparam logic [255:0] V08_EMPTY_CUSTOM =
        256'hb4b1a16bbd17c621fb41a71b8622301ccb345c5ebd55cec2eb3fed319e7cbc7c;

    //-------------------------------------------------------------------------
    // Hand anchor for the byte swap. MEAS_M01 reversed byte by byte. This is
    // the same value pq_measurement_tb.sv:109 records for M01, independently
    // arrived at. A round trip ALONE also passes for the identity function,
    // so the anchor is what actually proves the swap.
    //-------------------------------------------------------------------------
    localparam logic [255:0] MEAS_M01_SWAPPED =
        256'h959b61960366c705b889e2c09ffaead296e296475f32a610732ab9eac293182a;

    //-------------------------------------------------------------------------
    // Drive helpers
    //-------------------------------------------------------------------------
    task automatic clear_inputs;
        begin
            start       = 1'b0;
            tile_key    = '0;
            tile_id     = '0;
            epoch       = '0;
            nonce       = '0;
            measurement = '0;
            tag_len_sel = TAG_LEN_256;
        end
    endtask

    task automatic apply(input logic [255:0] k,
                         input logic [55:0]  t,
                         input logic [79:0]  e,
                         input logic [127:0] n,
                         input logic [255:0] m,
                         input logic [1:0]   ls);
        begin
            tile_key    = k;
            tile_id     = t;
            epoch       = e;
            nonce       = n;
            measurement = m;
            tag_len_sel = ls;
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(posedge clk);          // request latched on this edge
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_done(input integer limit, output logic ok);
        integer cycles;
        begin
            cycles = 0;
            while ((done !== 1'b1) && (cycles < limit)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            ok = (done === 1'b1);
            if (ok !== 1'b1) $display("    TIMEOUT after %0d cycles", cycles);
        end
    endtask

    //-------------------------------------------------------------------------
    // One accepted operation, full protocol contract checked.
    //-------------------------------------------------------------------------
    task automatic run_vector(input string        name,
                              input logic [255:0] expect_rtl,
                              input logic [1:0]   len_sel);
        logic ok;
        logic t_ok;
        begin
            while (busy === 1'b1) @(posedge clk);

            pulse_start();

            #1;
            chk(busy === 1'b1, $sformatf("%s : busy asserted", name));

            wait_done(3000, ok);

            if (ok !== 1'b1) begin
                chk(1'b0, $sformatf("%s : done asserted", name));
            end
            else begin
                chk(err === 1'b0, $sformatf("%s : err NOT asserted", name));

                // busy is LOW on the done cycle - kmac128 / pq_measurement
                // convention, frozen in the module header.
                chk(busy === 1'b0, $sformatf("%s : busy low on done cycle", name));

                if (len_sel == TAG_LEN_256) begin
                    t_ok = (tag === expect_rtl);
                    chk(t_ok, $sformatf("%s : tag", name));
                    chk(tag_bytes === 6'd32, $sformatf("%s : tag_bytes = 32", name));
                end
                else begin
                    t_ok = (tag[127:0] === expect_rtl[127:0]);
                    chk(t_ok, $sformatf("%s : tag[127:0]", name));
                    chk(tag[255:128] === 128'd0,
                        $sformatf("%s : upper half zeroed", name));
                    chk(tag_bytes === 6'd16, $sformatf("%s : tag_bytes = 16", name));
                end

                if (t_ok !== 1'b1) begin
                    $display("    expected (printed) = %064h", bswap256(expect_rtl));
                    $display("    got      (printed) = %064h", bswap256(tag));
                end

                @(posedge clk);
                #1;
                chk(done === 1'b0, $sformatf("%s : done is a one-cycle pulse", name));
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // One REJECTED operation. The handshake must still complete, fast.
    //-------------------------------------------------------------------------
    task automatic run_invalid(input string      name,
                               input logic [1:0] bad_sel);
        logic ok;
        begin
            while (busy === 1'b1) @(posedge clk);

            @(negedge clk);
            apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, bad_sel);

            pulse_start();

            // A rejected request must NOT run a KMAC. 20 cycles is far less
            // than the ~3 permutations an accepted request needs, so this
            // bound is itself a check.
            wait_done(20, ok);

            chk(ok,             $sformatf("%s : handshake completed, no hang", name));
            chk(err === 1'b1,   $sformatf("%s : err asserted", name));
            chk(tag === 256'd0, $sformatf("%s : tag forced to zero", name));
            chk(tag_bytes === 6'd0, $sformatf("%s : tag_bytes = 0", name));

            @(posedge clk);
            #1;
            chk(done === 1'b0, $sformatf("%s : done is a one-cycle pulse", name));
            chk(err  === 1'b0, $sformatf("%s : err is a one-cycle pulse",  name));
        end
    endtask

    //-------------------------------------------------------------------------
    // Reset
    //-------------------------------------------------------------------------
    task automatic reset_dut;
        begin
            clear_inputs();
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;

            chk(busy      === 1'b0,   "reset: busy = 0");
            chk(done      === 1'b0,   "reset: done = 0");
            chk(err       === 1'b0,   "reset: err  = 0");
            chk(tag       === 256'd0, "reset: tag  = 0");
        end
    endtask

    //-------------------------------------------------------------------------
    // Global watchdog
    //-------------------------------------------------------------------------
    initial begin : watchdog
        #2000000;
        $display("[FAIL] GLOBAL TIMEOUT - simulation did not finish");
        $finish;
    end

    //-------------------------------------------------------------------------
    // Main
    //-------------------------------------------------------------------------
    logic ok;
    logic [255:0] obs_v01;   // OBSERVED baseline tag, captured at runtime (not the golden constant)

    initial begin

        checks = 0;
        errors = 0;

        $display("================================================");
        $display("  PQ-ATTEST STAGE 7 - ATTESTATION TAG");
        $display("  TAG = KMAC128( K_tile,");
        $display("                 TILE_ID||EPOCH||NONCE||MEASUREMENT,");
        $display("                 \"PQ-ATTEST-AUTH\", L )");
        $display("================================================");

        reset_dut();

        //---------------------------------------------------------------------
        $display("\n--- byte-order self test ---");
        //---------------------------------------------------------------------
        chk(bswap256(MEAS_M01) === MEAS_M01_SWAPPED,
            "bswap256 anchor: MEAS_M01 matches the hand-computed reversal");
        chk(bswap256(bswap256(V01)) === V01,
            "bswap256 round trip over 32 bytes");

        //---------------------------------------------------------------------
        $display("\n--- golden vectors, L=256 ---");
        //---------------------------------------------------------------------
        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_256);
        run_vector("V01 baseline", V01, TAG_LEN_256);
        obs_v01 = tag;   // capture the DUT's ACTUAL baseline output for the differs-from-baseline checks

        @(negedge clk);
        apply(KEY_T, TILE_MUT, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_256);
        run_vector("V02 TILE_ID mutation", V02, TAG_LEN_256);
        chk(tag !== obs_v01, "V02 TILE_ID mutation : differs from baseline");

        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_M, NONCE_A, MEAS_M01, TAG_LEN_256);
        run_vector("V03 EPOCH mutation", V03, TAG_LEN_256);
        chk(tag !== obs_v01, "V03 EPOCH mutation : differs from baseline");

        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_M, MEAS_M01, TAG_LEN_256);
        run_vector("V04 NONCE mutation", V04, TAG_LEN_256);
        chk(tag !== obs_v01, "V04 NONCE mutation : freshness is bound into the tag");

        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_MUT, TAG_LEN_256);
        run_vector("V05 MEASUREMENT mutation", V05, TAG_LEN_256);
        chk(tag !== obs_v01, "V05 MEASUREMENT mutation : differs from baseline");

        @(negedge clk);
        apply(KEY_MUT, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_256);
        run_vector("V06 KEY mutation", V06, TAG_LEN_256);
        chk(tag !== obs_v01, "V06 KEY mutation : differs from baseline");

        //---------------------------------------------------------------------
        $display("\n--- output length is ABSORBED, not truncated ---");
        //---------------------------------------------------------------------
        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_128);
        run_vector("V07 baseline L=128", {128'd0, V07}, TAG_LEN_128);
        // THE discriminating check. If right_encode(L) were not absorbed, or
        // the domain byte did not move with it, these would be equal.
        // Compared against the OBSERVED L=256 baseline (obs_v01), not the golden
        // constant: a mutation that shifts every tag must not pass this for free
        // (same vacuity class as the M3 finding).
        chk(tag[127:0] !== obs_v01[127:0],
            "V07 : L=128 tag is NOT the truncated L=256 tag");

        //---------------------------------------------------------------------
        $display("\n--- domain separation ---");
        //---------------------------------------------------------------------
        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_256);
        run_vector("V08 customization check", V01, TAG_LEN_256);
        // V08_EMPTY_CUSTOM is what this DUT emits if custom_len is left at 0 -
        // the single most likely Stage 7 wiring bug, and one that leaves every
        // other vector passing.
        chk(tag !== V08_EMPTY_CUSTOM, "V08 : customization is NOT empty");

        //---------------------------------------------------------------------
        $display("\n--- invalid tag_len_sel is REJECTED, not coerced ---");
        //---------------------------------------------------------------------
        run_invalid("bad_sel 2'b10", 2'b10);
        run_invalid("bad_sel 2'b11", 2'b11);

        // A rejected request must leave no residue.
        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_256);
        run_vector("recovery after reject", V01, TAG_LEN_256);

        //---------------------------------------------------------------------
        $display("\n--- back to back ---");
        //---------------------------------------------------------------------
        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_256);
        run_vector("B2B A (V01)", V01, TAG_LEN_256);

        @(negedge clk);
        apply(KEY_T, TILE_MUT, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_256);
        run_vector("B2B B (V02)", V02, TAG_LEN_256);

        //---------------------------------------------------------------------
        $display("\n--- protocol: start while busy ---");
        //---------------------------------------------------------------------
        // Request A is launched, then a SECOND request with DIFFERENT inputs
        // is asserted mid-operation. The result must still be A's tag.
        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, TAG_LEN_256);
        pulse_start();

        repeat (4) @(posedge clk);
        #1;
        chk(busy === 1'b1, "start while busy : DUT is busy before the 2nd start");

        @(negedge clk);
        apply(KEY_MUT, TILE_MUT, EPOCH_M, NONCE_M, MEAS_MUT, TAG_LEN_128);
        pulse_start();

        wait_done(3000, ok);
        chk(ok,                  "start while busy : operation still completed");
        chk(tag === V01,         "start while busy : second request was NOT latched");
        chk(tag_bytes === 6'd32, "start while busy : tag_len_sel NOT overwritten");

        @(posedge clk);
        #1;

        // Non-vacuity guard: the ignored request must be one that WOULD have
        // produced a different answer. Run it properly and confirm.
        @(negedge clk);
        apply(KEY_MUT, TILE_MUT, EPOCH_M, NONCE_M, MEAS_MUT, TAG_LEN_128);
        pulse_start();
        wait_done(3000, ok);
        chk(ok, "start while busy : ignored request runs when issued properly");
        chk(tag[127:0] !== obs_v01[127:0],
            "start while busy : the ignored request was genuinely different");
        @(posedge clk);
        #1;

        //---------------------------------------------------------------------
        $display("\n--- negative control ---");
        //---------------------------------------------------------------------
        // One bit of the measurement, flipped. If this passes, the TB cannot
        // detect a broken DUT and has verified nothing.
        @(negedge clk);
        apply(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_MUT, TAG_LEN_256);
        run_vector("negative control", V05, TAG_LEN_256);
        chk(tag !== obs_v01,
            "negative control : 1-bit MEASUREMENT change alters the tag");

        //---------------------------------------------------------------------
        $display("\n================================================");
        $display("           STAGE 7 ATTESTATION TAG TB");
        $display("================================================");
        $display("CHECKS : %0d", checks);
        $display("ERRORS : %0d", errors);
        $display("");

        if (errors == 0) begin
            $display("******** STAGE 7 PASS ********");
            $display("");
            $display("V01 baseline L=256      : PASS");
            $display("V02 TILE_ID separation  : PASS");
            $display("V03 EPOCH separation    : PASS");
            $display("V04 NONCE freshness     : PASS");
            $display("V05 MEASUREMENT binding : PASS");
            $display("V06 KEY binding         : PASS");
            $display("V07 L=128 absorbed      : PASS");
            $display("V08 domain separation   : PASS");
            $display("Invalid tag_len_sel     : PASS");
            $display("Byte-order self test    : PASS");
            $display("Back-to-back            : PASS");
            $display("Start while busy        : PASS");
            $display("Negative control        : PASS");
            $display("ZERO TEST ERRORS");
        end
        else begin
            $display("******** STAGE 7 FAIL ********");
        end

        $display("================================================");
        $finish;
    end

endmodule