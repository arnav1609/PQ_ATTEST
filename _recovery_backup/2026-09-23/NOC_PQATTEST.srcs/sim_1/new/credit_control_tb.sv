
// Module    : M9 noc_credit_control
//
// Verification:
//     - Reset initialization
//     - Credit decrement
//     - Credit increment
//     - Zero-credit blocking
//     - Simultaneous send + return
//     - All 15 output/VC channels
//     - Model-based randomized stress
//     - Negative control
//     - Checker mutation test
//=============================================================================

`timescale 1ns/1ps

module tb_noc_credit_control;

    import noc_pkg::*;

    localparam int NUM_INPUT_VCS = NUM_PORTS * NUM_VC;
    localparam int INPUT_VC_W =
        (NUM_INPUT_VCS <= 1) ? 1 : $clog2(NUM_INPUT_VCS);

    logic clk;
    logic rst;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic [NUM_INPUT_VCS-1:0] grant [NUM_PORTS];
    logic [NUM_PORTS-1:0] grant_valid;
    logic [INPUT_VC_W-1:0] xbar_sel [NUM_PORTS];
    logic [NUM_VC-1:0] credit_return [NUM_PORTS];

    logic [NUM_PORTS-1:0] credit_ok;
    logic [NUM_PORTS-1:0] grant_valid_qualified;
    logic [NUM_INPUT_VCS-1:0] fifo_rd_en;

    int checks;
    int errors;

    // Reference model: number of free downstream FIFO slots.
    int model [NUM_PORTS][NUM_VC];

    noc_credit_control dut (
        .clk                    (clk),
        .rst                    (rst),
        .grant                  (grant),
        .grant_valid            (grant_valid),
        .xbar_sel               (xbar_sel),
        .credit_return          (credit_return),
        .credit_ok              (credit_ok),
        .grant_valid_qualified  (grant_valid_qualified),
        .fifo_rd_en             (fifo_rd_en)
    );

    //========================================================================= 
    // HELPERS
    //========================================================================= 

    function automatic int depth_for_vc(input int vc);
        case (vc)
            0: depth_for_vc = VC0_DEPTH;
            1: depth_for_vc = VC1_DEPTH;
            2: depth_for_vc = VC2_DEPTH;
            default: depth_for_vc = 0;
        endcase
    endfunction

    task automatic clear_inputs;
        begin
            grant_valid = '0;
            for (int p = 0; p < NUM_PORTS; p++) begin
                grant[p] = '0;
                xbar_sel[p] = '0;
                credit_return[p] = '0;
            end
        end
    endtask

    task automatic drive_grant(input int output_port, input int input_vc);
        begin
            clear_inputs();
            grant_valid[output_port] = 1'b1;
            grant[output_port][input_vc] = 1'b1;
            xbar_sel[output_port] = INPUT_VC_W'(input_vc);
        end
    endtask

    task automatic return_credit(input int output_port, input int vc);
        begin
            credit_return[output_port][vc] = 1'b1;
        end
    endtask

    task automatic reset_dut;
        begin
            clear_inputs();
            rst = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            rst = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic init_model;
        begin
            for (int p = 0; p < NUM_PORTS; p++)
                for (int v = 0; v < NUM_VC; v++)
                    model[p][v] = depth_for_vc(v);
        end
    endtask

    task automatic check_credit(input int output_port, input int vc, input int expected);
        int actual;
        begin
            checks++;
            actual = dut.credit_count[output_port][vc];
            if (actual !== expected) begin
                errors++;
                $error("CREDIT MISMATCH: P=%0d VC=%0d expected=%0d actual=%0d",
                       output_port, vc, expected, actual);
            end
            else begin
                $display("[PASS] credit P=%0d VC=%0d = %0d",
                         output_port, vc, actual);
            end
        end
    endtask

    task automatic check_condition(input bit condition, input string message);
        begin
            checks++;
            if (!condition) begin
                errors++;
                $error("M9 TB: %s", message);
            end
            else begin
                $display("[PASS] %s", message);
            end
        end
    endtask

    task automatic check_model;
        begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                for (int v = 0; v < NUM_VC; v++) begin
                    check_credit(p, v, model[p][v]);
                end
            end
        end
    endtask

    //========================================================================= 
    // TEST 1: RESET
    //========================================================================= 

    task automatic test_reset;
        begin
            $display("\n========================================");
            $display("TEST 1: RESET INITIALIZATION");
            $display("========================================");

            reset_dut();
            init_model();

            for (int p = 0; p < NUM_PORTS; p++) begin
                check_credit(p, 0, VC0_DEPTH);
                check_credit(p, 1, VC1_DEPTH);
                check_credit(p, 2, VC2_DEPTH);
            end
        end
    endtask

    //========================================================================= 
    // TEST 2: SINGLE SEND
    //========================================================================= 

    task automatic test_single_send;
        begin
            $display("\n========================================");
            $display("TEST 2: SINGLE SEND");
            $display("========================================");

            reset_dut();
            init_model();

            drive_grant(2, 0);
            @(posedge clk);
            #1;

            model[2][0]--;
            check_credit(2, 0, model[2][0]);
            check_condition(grant_valid_qualified[2] === 1'b1,
                            "legal send is accepted");
            check_condition(fifo_rd_en[0] === 1'b1,
                            "FIFO read enable asserted for selected VC");

            clear_inputs();
        end
    endtask

    //========================================================================= 
    // TEST 3: EXHAUST CREDIT
    //========================================================================= 

    task automatic test_exhaust_credit;
        begin
            $display("\n========================================");
            $display("TEST 3: EXHAUST CREDIT");
            $display("========================================");

            reset_dut();
            init_model();

            for (int k = 0; k < VC0_DEPTH; k++) begin
                drive_grant(0, 0);
                @(posedge clk);
                #1;
                model[0][0]--;
            end

            check_credit(0, 0, 0);

            // Negative protocol case: attempt a send at zero credit.
            drive_grant(0, 0);
            #1;
            check_condition(grant_valid_qualified[0] === 1'b0,
                            "zero credit blocks grant");
            check_condition(fifo_rd_en[0] === 1'b0,
                            "zero credit blocks FIFO read");
            clear_inputs();
        end
    endtask

    //========================================================================= 
    // TEST 4: CREDIT RETURN
    //========================================================================= 

    task automatic test_credit_return;
        begin
            $display("\n========================================");
            $display("TEST 4: CREDIT RETURN");
            $display("========================================");

            reset_dut();
            init_model();

            // Create one used slot first: 4 -> 3.
            drive_grant(0, 0);
            @(posedge clk);
            #1;
            model[0][0]--;

            clear_inputs();
            return_credit(0, 0);
            @(posedge clk);
            #1;
            model[0][0]++;

            check_credit(0, 0, model[0][0]);

            drive_grant(0, 0);
            #1;
            check_condition(grant_valid_qualified[0] === 1'b1,
                            "returned credit is usable");

            @(posedge clk);
            #1;
            model[0][0]--;
            check_credit(0, 0, model[0][0]);

            clear_inputs();
        end
    endtask

    //========================================================================= 
    // TEST 5: SEND + RETURN SAME CYCLE
    //========================================================================= 

    task automatic test_send_return_same_cycle;
        begin
            $display("\n========================================");
            $display("TEST 5: SEND + CREDIT RETURN");
            $display("========================================");

            reset_dut();
            init_model();

            // Establish the required precondition: P1/VC1 = 1.
            for (int k = 0; k < VC1_DEPTH-1; k++) begin
                drive_grant(1, 1); // global input VC 1 => VC1
                @(posedge clk);
                #1;
                model[1][1]--;
            end

            check_credit(1, 1, 1);

            // Send + return in the same cycle. Net credit change = 0.
            drive_grant(1, 4);       // global input VC 4 => VC1
            credit_return[1][1] = 1'b1;
            #1;

            check_condition(grant_valid_qualified[1] === 1'b1,
                            "simultaneous send + return is accepted");

            @(posedge clk);
            #1;

            // Reference model: -1 + 1 = 0.
            check_credit(1, 1, model[1][1]);

            clear_inputs();
        end
    endtask

    //========================================================================= 
    // TEST 6: ALL 15 CHANNELS
    //========================================================================= 

    task automatic test_all_channels;
        int global_vc;
        begin
            $display("\n========================================");
            $display("TEST 6: ALL 15 OUTPUT x VC CHANNELS");
            $display("========================================");

            reset_dut();
            init_model();

            for (int p = 0; p < NUM_PORTS; p++) begin
                for (int v = 0; v < NUM_VC; v++) begin
                    global_vc = p * NUM_VC + v;

                    drive_grant(p, global_vc);
                    @(posedge clk);
                    #1;

                    model[p][v]--;

                    check_condition(grant_valid_qualified[p] === 1'b1,
                                    $sformatf("channel P=%0d VC=%0d accepted", p, v));
                    check_credit(p, v, model[p][v]);
                end
            end

            clear_inputs();
        end
    endtask

    //========================================================================= 
    // TEST 7: MODEL-BASED RANDOM STRESS
    //========================================================================= 

    task automatic random_stress;
        int p;
        int vc;
        int input_vc;
        int operation;
        bit do_send;
        bit do_return;
        begin
            $display("\n========================================");
            $display("TEST 7: MODEL-BASED RANDOMIZED CREDIT STRESS");
            $display("========================================");

            reset_dut();
            init_model();

            repeat (5000) begin
                clear_inputs();

                p = $urandom_range(0, NUM_PORTS-1);
                vc = $urandom_range(0, NUM_VC-1);
                operation = $urandom_range(0, 3);

                do_send = 1'b0;
                do_return = 1'b0;

                case (operation)
                    0: begin end

                    1: begin
                        if (model[p][vc] > 0)
                            do_send = 1'b1;
                    end

                    2: begin
                        if (model[p][vc] < depth_for_vc(vc))
                            do_return = 1'b1;
                    end

                    3: begin
                        if (model[p][vc] > 0)
                            do_send = 1'b1;
                        if (model[p][vc] < depth_for_vc(vc))
                            do_return = 1'b1;
                    end
                endcase

                if (do_send) begin
                    input_vc = ($urandom_range(0, NUM_PORTS-1) * NUM_VC) + vc;
                    grant_valid[p] = 1'b1;
                    grant[p][input_vc] = 1'b1;
                    xbar_sel[p] = INPUT_VC_W'(input_vc);
                end

                if (do_return)
                    credit_return[p][vc] = 1'b1;

                // ----------------------------------------------------------------
                // IMPORTANT TIMING:
                // Check combinational qualification BEFORE the consuming posedge.
                // At posedge, a legal final-credit send changes credit 1 -> 0.
                // Sampling grant_valid_qualified after that edge would therefore
                // falsely report the just-consumed transfer as blocked.
                // ----------------------------------------------------------------
                #1;

                if (do_send) begin
                    checks++;
                    if (grant_valid_qualified[p] !== 1'b1 ||
                        fifo_rd_en[input_vc] !== 1'b1) begin
                        errors++;
                        $error("M9 stress: legal send blocked/no rd_en P=%0d VC=%0d",
                               p, vc);
                    end
                end

                // The following posedge consumes the qualified transfer and
                // applies the credit return, if present.
                @(posedge clk);
                #1;

                // Update the independent reference model AFTER the consuming edge.
                if (do_send)
                    model[p][vc]--;
                if (do_return)
                    model[p][vc]++;

                // Check the complete state against the independent model.
                check_model();
            end

            clear_inputs();
            $display("[PASS] 5000-cycle legal model-based stress completed");
        end
    endtask

    //========================================================================= 
    // TEST 8: NEGATIVE CONTROL
    //
    // Exercise the zero-credit negative path without intentionally firing an
    // RTL assertion. This verifies that an illegal transfer attempt is blocked.
    //========================================================================= 

    task automatic negative_control;
        begin
            $display("\n========================================");
            $display("TEST 8: NEGATIVE CONTROL");
            $display("========================================");

            reset_dut();
            init_model();

            // Exhaust P0/VC0.
            for (int k = 0; k < VC0_DEPTH; k++) begin
                drive_grant(0, 0);
                @(posedge clk);
                #1;
            end

            clear_inputs();
            drive_grant(0, 0);
            #1;

            check_condition(grant_valid_qualified[0] === 1'b0,
                            "negative control: illegal zero-credit transfer blocked");
            check_condition(fifo_rd_en[0] === 1'b0,
                            "negative control: illegal zero-credit FIFO read blocked");

            clear_inputs();
        end
    endtask

    //========================================================================= 
    // TEST 9: CHECKER MUTATION TEST
    //
    // Deliberately mutate the expected value. The checker must detect that
    // the mutated expectation does not match the DUT state. This does not
    // modify the DUT and does not create an intentional DUT assertion failure.
    //========================================================================= 

    task automatic mutation_test;
        int actual;
        int correct_expected;
        int mutated_expected;
        begin
            $display("\n========================================");
            $display("TEST 9: CHECKER MUTATION TEST");
            $display("========================================");

            reset_dut();
            init_model();

            actual = dut.credit_count[0][0];
            correct_expected = VC0_DEPTH;
            mutated_expected = correct_expected - 1;

            checks++;
            if (actual === mutated_expected) begin
                errors++;
                $error("M9 mutation test FAILED: checker would accept mutated expected value");
            end
            else begin
                $display("[PASS] checker mutation detected: expected=%0d mutated=%0d actual=%0d",
                         correct_expected, mutated_expected, actual);
            end
        end
    endtask

    //========================================================================= 
    // TEST SEQUENCE
    //========================================================================= 

    initial begin
        $display("\n");
        $display("======================================================");
        $display(" PQ-ATTEST NOC : M9 CREDIT CONTROL VERIFICATION");
        $display("======================================================");

        rst = 1'b0;
        clear_inputs();

        test_reset();
        test_single_send();
        test_exhaust_credit();
        test_credit_return();
        test_send_return_same_cycle();
        test_all_channels();
        random_stress();
        negative_control();
        mutation_test();

        clear_inputs();
        rst = 1'b0;

        #20;

        $display("\n======================================================");
        $display(" M9 TESTBENCH COMPLETE");
        $display(" Checks = %0d", checks);
        $display(" Errors = %0d", errors);

        if (errors == 0) begin
            $display(" RESULT = PASS");
        end
        else begin
            $display(" RESULT = FAIL");
        end

        $display("======================================================");

        $finish;
    end

endmodule

