`timescale 1ns/1ps

module m11_tb;

    import noc_pkg::*;

    //============================================================
    // DUT signals
    //============================================================

    logic [31:0] addr;
    logic        addr_valid;

    logic           is_local;
    local_target_e  local_sel;
    addr_decode_t   remote;
    logic           bus_error;

    //============================================================
    // DUT
    //============================================================

    noc_addr_decoder #(
        .LOCAL_TILE_ID(0),
        .SELF_REMOTE_IS_ERROR(1'b1)
    ) dut (
        .addr       (addr),
        .addr_valid (addr_valid),
        .is_local   (is_local),
        .local_sel  (local_sel),
        .remote     (remote),
        .bus_error  (bus_error)
    );

    //============================================================
    // Checker
    //============================================================

    integer checks = 0;
    integer errors = 0;

    task automatic check(
        input logic condition,
        input string msg
    );
        begin
            checks++;

            if (condition)
                $display("[PASS] %s", msg);
            else begin
                errors++;
                $display("[FAIL] %s", msg);
            end
        end
    endtask

    //============================================================
    // Apply address
    //============================================================

    task automatic test_addr(input logic [31:0] a);
        begin
            addr = a;
            addr_valid = 1'b1;
            #1;
        end
    endtask

    //============================================================
    // Main
    //============================================================

    initial begin

        $display("");
        $display("==========================================");
        $display("        M11 ADDRESS DECODER TB");
        $display("==========================================");

        //========================================================
        // T01: addr_valid = 0
        //========================================================

        addr = 32'h0000_0000;
        addr_valid = 1'b0;
        #1;

        check(
            is_local === 1'b0,
            "T01 invalid address is not local"
        );

        check(
            local_sel === LOCAL_NONE,
            "T01 local_sel = LOCAL_NONE"
        );

        check(
            remote.valid === 1'b0,
            "T01 remote invalid"
        );

        check(
            bus_error === 1'b0,
            "T01 no error when addr_valid = 0"
        );

        //========================================================
        // T02: IMEM
        //========================================================

        test_addr(LOCAL_IMEM_BASE);

        check(
            is_local === 1'b1,
            "T02 IMEM is local"
        );

        check(
            local_sel === LOCAL_IMEM,
            "T02 IMEM selected"
        );

        check(
            bus_error === 1'b0,
            "T02 IMEM no error"
        );

        //========================================================
        // T03: DMEM
        //========================================================

        test_addr(LOCAL_DMEM_BASE);

        check(
            is_local === 1'b1,
            "T03 DMEM is local"
        );

        check(
            local_sel === LOCAL_DMEM,
            "T03 DMEM selected"
        );

        check(
            bus_error === 1'b0,
            "T03 DMEM no error"
        );

        //========================================================
        // T04: UART
        //========================================================

        test_addr(LOCAL_UART_BASE);

        check(
            is_local === 1'b1,
            "T04 UART is local"
        );

        check(
            local_sel === LOCAL_UART,
            "T04 UART selected"
        );

        //========================================================
        // T05: GPIO
        //========================================================

        test_addr(LOCAL_GPIO_BASE);

        check(
            is_local === 1'b1,
            "T05 GPIO is local"
        );

        check(
            local_sel === LOCAL_GPIO,
            "T05 GPIO selected"
        );

        //========================================================
        // T06: STATUS
        //========================================================

        test_addr(LOCAL_STATUS_BASE);

        check(
            is_local === 1'b1,
            "T06 STATUS is local"
        );

        check(
            local_sel === LOCAL_STATUS,
            "T06 STATUS selected"
        );

        //========================================================
        // T07: NI
        //========================================================

        test_addr(LOCAL_NI_BASE);

        check(
            is_local === 1'b1,
            "T07 NI is local"
        );

        check(
            local_sel === LOCAL_NI,
            "T07 NI selected"
        );

        //========================================================
        // T08: REMOTE TILE 1
        // address[27:24] = 1
        //========================================================

        test_addr(32'h2100_0000);

        check(
            is_local === 1'b0,
            "T08 remote tile 1 is not local"
        );

        check(
            remote.valid === 1'b1,
            "T08 remote tile 1 is valid"
        );

        check(
            bus_error === 1'b0,
            "T08 remote tile 1 no error"
        );

        //========================================================
        // T09: REMOTE TILE 2
        //========================================================

        test_addr(32'h2200_0000);

        check(
            remote.valid === 1'b1,
            "T09 remote tile 2 is valid"
        );

        check(
            bus_error === 1'b0,
            "T09 remote tile 2 no error"
        );

        //========================================================
        // T10: REMOTE TILE 3
        //========================================================

        test_addr(32'h2300_0000);

        check(
            remote.valid === 1'b1,
            "T10 remote tile 3 is valid"
        );

        check(
            bus_error === 1'b0,
            "T10 remote tile 3 no error"
        );

        //========================================================
        // T11: REMOTE TILE 4
        //========================================================

        test_addr(32'h2400_0000);

        check(
            remote.valid === 1'b1,
            "T11 remote tile 4 is valid"
        );

        check(
            bus_error === 1'b0,
            "T11 remote tile 4 no error"
        );

        //========================================================
        // T12: REMOTE TILE 5
        //========================================================

        test_addr(32'h2500_0000);

        check(
            remote.valid === 1'b1,
            "T12 remote tile 5 is valid"
        );

        check(
            bus_error === 1'b0,
            "T12 remote tile 5 no error"
        );

        //========================================================
        // T13: SELF REMOTE TILE 0
        //========================================================

        test_addr(32'h2000_0000);

        check(
            remote.valid === 1'b0,
            "T13 self-remote is rejected"
        );

        check(
            bus_error === 1'b1,
            "T13 self-remote gives bus error"
        );

        //========================================================
        // T14: ILLEGAL REMOTE TILE 6
        //========================================================

        test_addr(32'h2600_0000);

        check(
            remote.valid === 1'b0,
            "T14 illegal tile 6 is rejected"
        );

        check(
            bus_error === 1'b1,
            "T14 illegal tile 6 gives bus error"
        );

        //========================================================
        // T15: UNMAPPED ADDRESS
        //========================================================

        test_addr(32'h0800_0000);

        check(
            is_local === 1'b0,
            "T15 unmapped address is not local"
        );

        check(
            remote.valid === 1'b0,
            "T15 unmapped address is not remote"
        );

        check(
            bus_error === 1'b1,
            "T15 unmapped address gives bus error"
        );

        //========================================================
        // SUMMARY
        //========================================================

        $display("");
        $display("==========================================");
        $display("             M11 SUMMARY");
        $display("==========================================");
        $display("Checks : %0d", checks);
        $display("Errors : %0d", errors);

        if (errors == 0)
            $display("RESULT : PASS");
        else
            $display("RESULT : FAIL");

        $display("==========================================");

        if (errors == 0)
            $finish;
        else
            $fatal(1, "M11 TEST FAILED");

    end

endmodule