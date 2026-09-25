`timescale 1ns/1ps

module testbench;

    logic clk;
    logic rst;
    logic start;

    logic [2175:0] message_block;
    logic [8:0]    message_len;

    logic [255:0] digest;
    logic busy;
    logic done;

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------

    sha3_256_core dut (

        .clk          (clk),
        .rst          (rst),
        .start        (start),

        .message_block(message_block),
        .message_len  (message_len),

        .digest       (digest),
        .busy         (busy),
        .done         (done)

    );

    // --------------------------------------------------------
    // Clock
    // --------------------------------------------------------

    initial begin
        clk = 1'b0;

        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // Run one SHA3 test
    // --------------------------------------------------------

    task automatic run_test;

        input integer len;
        input [255:0] expected;

        integer i;

        begin

            // Clear input buffer
            message_block = 2176'b0;

            // Fill with ASCII 'a'
            for (i = 0; i < len; i = i + 1) begin

                message_block[i*8 +: 8] = 8'h61;

            end

            message_len = len;

            // Start pulse
            @(posedge clk);

            start = 1'b1;

            @(posedge clk);

            start = 1'b0;

            // Wait for completion
            wait(done == 1'b1);

            #1;

            if (digest === expected) begin

                $display("PASS");

            end

            else begin

                $display("FAIL");

            end

            $display("Length   = %0d", len);
            $display("Digest   = %064h", digest);
            $display("Expected = %064h", expected);

            $display("");

            @(posedge clk);

        end

    endtask


    // --------------------------------------------------------
    // Tests
    // --------------------------------------------------------

    initial begin

        rst = 1'b1;
        start = 1'b0;

        message_block = 2176'b0;
        message_len = 9'd0;

        repeat (3)
            @(posedge clk);

        rst = 1'b0;

        @(posedge clk);

        // ====================================================
        // TEST 1
        // 135 x 'a'
        //
        // Expected:
        // 8094bb53c44cfb1e67b7c30447f9a1c33696d2463ecc1d9c92538913392843c9
        // ====================================================

        $display("==============================================");
        $display("SHA3-256 MULTI-BLOCK TEST 1");
        $display("135 x 'a'");
        $display("==============================================");

        run_test(
            135,
            256'h8094bb53c44cfb1e67b7c30447f9a1c33696d2463ecc1d9c92538913392843c9
        );


        // ====================================================
        // TEST 2
        // 136 x 'a'
        //
        // Exact rate boundary.
        //
        // Expected:
        // 3fc5559f14db8e453a0a3091edbd2bc25e11528d81c66fa570a4efdcc2695ee1
        // ====================================================

        $display("==============================================");
        $display("SHA3-256 MULTI-BLOCK TEST 2");
        $display("136 x 'a'");
        $display("==============================================");

        run_test(
            136,
            256'h3fc5559f14db8e453a0a3091edbd2bc25e11528d81c66fa570a4efdcc2695ee1
        );


        // ====================================================
        // TEST 3
        // 137 x 'a'
        //
        // Expected:
        // f8d6846cedd2ccfadf15c5879ef95af724d799eed7391fb1c91f95344e738614
        // ====================================================

        $display("==============================================");
        $display("SHA3-256 MULTI-BLOCK TEST 3");
        $display("137 x 'a'");
        $display("==============================================");

        run_test(
            137,
            256'hf8d6846cedd2ccfadf15c5879ef95af724d799eed7391fb1c91f95344e738614
        );


        // ====================================================
        // COMPLETE
        // ====================================================

        $display("==============================================");
        $display("SHA3-256 MULTI-BLOCK VERIFICATION COMPLETE");
        $display("==============================================");

        $finish;

    end

endmodule
