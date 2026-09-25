`timescale 1ns/1ps

module tb_keccak_f1600;

    reg  [1599:0] state_in;
    wire [1599:0] state_out;

    integer i;
    integer pass_count;
    integer fail_count;

    reg [63:0] expected_lane;


    // =========================================================
    // DUT
    // =========================================================

    keccak_f1600 dut (
        .state_in  (state_in),
        .state_out (state_out)
    );


    // =========================================================
    // Expected Keccak-f[1600] output
    //
    // All-zero input state.
    //
    // Lane ordering:
    // lane = x + 5*y
    // =========================================================

    function [63:0] get_expected_lane;

        input integer lane;

        begin

            case (lane)

                0:
                    get_expected_lane =
                        64'hf1258f7940e1dde7;

                1:
                    get_expected_lane =
                        64'h84d5ccf933c0478a;

                2:
                    get_expected_lane =
                        64'hd598261ea65aa9ee;

                3:
                    get_expected_lane =
                        64'hbd1547306f80494d;

                4:
                    get_expected_lane =
                        64'h8b284e056253d057;


                5:
                    get_expected_lane =
                        64'hff97a42d7f8e6fd4;

                6:
                    get_expected_lane =
                        64'h90fee5a0a44647c4;

                7:
                    get_expected_lane =
                        64'h8c5bda0cd6192e76;

                8:
                    get_expected_lane =
                        64'had30a6f71b19059c;

                9:
                    get_expected_lane =
                        64'h30935ab7d08ffc64;


                10:
                    get_expected_lane =
                        64'heb5aa93f2317d635;

                11:
                    get_expected_lane =
                        64'ha9a6e6260d712103;

                12:
                    get_expected_lane =
                        64'h81a57c16dbcf555f;

                13:
                    get_expected_lane =
                        64'h43b831cd0347c826;

                14:
                    get_expected_lane =
                        64'h01f22f1a11a5569f;


                15:
                    get_expected_lane =
                        64'h05e5635a21d9ae61;

                16:
                    get_expected_lane =
                        64'h64befef28cc970f2;

                17:
                    get_expected_lane =
                        64'h613670957bc46611;

                18:
                    get_expected_lane =
                        64'hb87c5a554fd00ecb;

                19:
                    get_expected_lane =
                        64'h8c3ee88a1ccf32c8;


                20:
                    get_expected_lane =
                        64'h940c7922ae3a2614;

                21:
                    get_expected_lane =
                        64'h1841f924a2c509e4;

                22:
                    get_expected_lane =
                        64'h16f53526e70465c2;

                23:
                    get_expected_lane =
                        64'h75f644e97f30a13b;

                24:
                    get_expected_lane =
                        64'heaf1ff7b5ceca249;

                default:
                    get_expected_lane =
                        64'h0000000000000000;

            endcase

        end

    endfunction


    // =========================================================
    // Test
    // =========================================================

    initial begin

        pass_count = 0;
        fail_count = 0;

        // -----------------------------------------------------
        // Test vector:
        //
        // Input = 1600-bit all-zero state
        // -----------------------------------------------------

        state_in = 1600'b0;

        #10;


        $display("");
        $display("==================================================");
        $display(" PQ-Attest Keccak-f[1600] Full Testbench");
        $display("==================================================");

        $display("");
        $display("Input state:");
        $display("%0400h", state_in);

        $display("");
        $display("Output state:");
        $display("%0400h", state_out);

        $display("");
        $display("Checking all 25 lanes...");
        $display("");


        // -----------------------------------------------------
        // Check all 25 lanes
        // -----------------------------------------------------

        for (i = 0; i < 25; i = i + 1) begin

            expected_lane = get_expected_lane(i);

            if (state_out[i*64 +: 64] === expected_lane) begin

                $display(
                    "Lane %02d : PASS | Expected = %016h",
                    i,
                    expected_lane
                );

                pass_count = pass_count + 1;

            end
            else begin

                $display(
                    "Lane %02d : FAIL",
                    i
                );

                $display(
                    "          Expected = %016h",
                    expected_lane
                );

                $display(
                    "          Actual   = %016h",
                    state_out[i*64 +: 64]
                );

                fail_count = fail_count + 1;

            end

        end


        // =====================================================
        // Final result
        // =====================================================

        $display("");
        $display("--------------------------------------------------");
        $display(" Keccak-f[1600] Verification Result");
        $display("--------------------------------------------------");

        $display("PASS COUNT = %0d / 25", pass_count);
        $display("FAIL COUNT = %0d / 25", fail_count);


        if (fail_count == 0) begin

            $display("");
            $display("**********************************************");
            $display(" PASS: ALL 25 LANES MATCH PYTHON REFERENCE");
            $display("**********************************************");

        end
        else begin

            $display("");
            $display("**********************************************");
            $display(" FAIL: KECCAK OUTPUT MISMATCH");
            $display("**********************************************");

        end


        $display("");

        $finish;

    end

endmodule