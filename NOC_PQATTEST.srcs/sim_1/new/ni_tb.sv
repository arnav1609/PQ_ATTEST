`timescale 1ns/1ps

module tb_noc_ni;

    import noc_pkg::*;

    localparam int DUT_TILE_ID = int'(TILE_CPU0);
    localparam coord_t DUT_COORD = tile_to_coord(TILE_CPU0);
    localparam time TSETTLE = 1ns;

    logic clk = 1'b0;
    logic rst;

    //=====================================================================
    // TX: Tile -> NoC
    //=====================================================================

    logic tx_valid;
    logic tx_ready;

    coord_t tx_dest_coord;
    msg_type_e tx_msg_type;
    logic [10:0] tx_control;

    logic [FLIT_WIDTH-1:0] tx_payload_data;
    logic tx_payload_valid;
    logic tx_payload_ready;

    logic [MAC_TAG_BITS-1:0] tx_mac_tag;
    logic tx_error;

    //=====================================================================
    // NoC TX
    //=====================================================================

    flit_t noc_tx_flit;
    logic noc_tx_valid;
    logic noc_tx_ready;

    //=====================================================================
    // NoC RX
    //=====================================================================

    flit_t noc_rx_flit;
    logic noc_rx_valid;
    logic noc_rx_ready;

    //=====================================================================
    // RX: NoC -> Tile
    //=====================================================================

    coord_t rx_src_coord;
    coord_t rx_dest_coord;
    msg_type_e rx_msg_type;

    logic [10:0] rx_control;
    logic [4:0] rx_length;
    logic rx_head_valid;

    logic [FLIT_WIDTH-1:0] rx_payload_data;
    logic rx_payload_valid;
    logic rx_payload_last;
    logic rx_ready;

    logic [MAC_TAG_BITS-1:0] rx_mac_tag;
    logic rx_mac_valid;

    logic rx_protocol_error;
    logic rx_length_error;

    logic tx_busy;
    logic rx_busy;

    //=====================================================================
    // Transaction tags
    //=====================================================================

    txn_tag_t tag0;
    txn_tag_t tag1;

    //=====================================================================
    // DUT
    //=====================================================================

    noc_network_interface #(
        .LOCAL_TILE_ID(DUT_TILE_ID)
    ) dut (
        .clk(clk),
        .rst(rst),

        .tx_valid(tx_valid),
        .tx_ready(tx_ready),

        .tx_dest_coord(tx_dest_coord),
        .tx_msg_type(tx_msg_type),
        .tx_control(tx_control),

        .tx_payload_data(tx_payload_data),
        .tx_payload_valid(tx_payload_valid),
        .tx_payload_ready(tx_payload_ready),

        .tx_mac_tag(tx_mac_tag),
        .tx_error(tx_error),

        .noc_tx_flit(noc_tx_flit),
        .noc_tx_valid(noc_tx_valid),
        .noc_tx_ready(noc_tx_ready),

        .noc_rx_flit(noc_rx_flit),
        .noc_rx_valid(noc_rx_valid),
        .noc_rx_ready(noc_rx_ready),

        .rx_src_coord(rx_src_coord),
        .rx_dest_coord(rx_dest_coord),
        .rx_msg_type(rx_msg_type),
        .rx_control(rx_control),
        .rx_length(rx_length),
        .rx_head_valid(rx_head_valid),

        .rx_payload_data(rx_payload_data),
        .rx_payload_valid(rx_payload_valid),
        .rx_payload_last(rx_payload_last),
        .rx_ready(rx_ready),

        .rx_mac_tag(rx_mac_tag),
        .rx_mac_valid(rx_mac_valid),

        .rx_protocol_error(rx_protocol_error),
        .rx_length_error(rx_length_error),
        .ni_status_clr(1'b0),   // N-8.1

        .tx_busy(tx_busy),
        .rx_busy(rx_busy)
    );

    //=====================================================================
    // Clock
    //=====================================================================

    always #5 clk = ~clk;

    //=====================================================================
    // Test counters
    //=====================================================================

    integer checks = 0;
    integer errors = 0;

    //=====================================================================
    // Checker
    //=====================================================================

    task automatic check(
        input logic condition,
        input string description
    );
        begin
            checks++;

            if (condition) begin
                $display("[PASS] %s", description);
            end
            else begin
                errors++;

                $display(
                    "[FAIL] %s @ %0t",
                    description,
                    $time
                );
            end
        end
    endtask

    //=====================================================================
    // Construct HEAD flit
    //=====================================================================

    function automatic logic [FLIT_WIDTH-1:0] make_head(
        input coord_t dest,
        input coord_t src,
        input msg_type_e msg,
        input logic [4:0] length,
        input logic [10:0] control
    );

        head_flit_t h;

        begin
            h = '0;

            h.dest_x = dest.x;
            h.dest_y = dest.y;

            h.src_x = src.x;
            h.src_y = src.y;

            h.msg_type = msg;
            h.length = length;

            h.control.raw = control;

            make_head = h;
        end

    endfunction

    //=====================================================================
    // Reset
    //=====================================================================

    task automatic reset_dut;

        begin
            rst = 1'b1;

            tx_valid = 1'b0;
            tx_dest_coord = '0;
            tx_msg_type = MSG_MEM_RD_REQ;
            tx_control = '0;

            tx_payload_data = '0;
            tx_payload_valid = 1'b0;

            tx_mac_tag = '0;

            noc_tx_ready = 1'b1;

            noc_rx_flit = '0;
            noc_rx_valid = 1'b0;

            rx_ready = 1'b1;

            tag0 = '0;
            tag1 = '0;

            repeat (3)
                @(posedge clk);

            #TSETTLE;

            rst = 1'b0;

            @(posedge clk);
            #TSETTLE;
        end

    endtask

    //=====================================================================
    // Send transaction request
    //=====================================================================

    task automatic send_request(
        input coord_t dest,
        input msg_type_e msg,
        input logic [10:0] control
    );

        begin
            @(negedge clk);

            tx_dest_coord = dest;
            tx_msg_type = msg;
            tx_control = control;

            tx_valid = 1'b1;

            #TSETTLE;

            while (!tx_ready) begin
                @(negedge clk);
                #TSETTLE;
            end

            @(posedge clk);
            #TSETTLE;

            tx_valid = 1'b0;
        end

    endtask

    //=====================================================================
    // Check transmitted HEAD
    //=====================================================================

    task automatic check_tx_head(
        input coord_t expected_dest,
        input msg_type_e expected_msg,
        input string test_name,
        output txn_tag_t captured_tag
    );

        head_flit_t h;

        begin

            while (!(noc_tx_valid && noc_tx_ready)) begin
                @(negedge clk);
                #TSETTLE;
            end

            h = head_flit_t'(noc_tx_flit.flit_data);

            captured_tag = get_txn_tag(h.control.raw);

            check(
                noc_tx_flit.flit_type === FLIT_HEAD,
                {test_name, " : HEAD"}
            );

            check(
                noc_tx_flit.vc_id === message_to_vc(expected_msg),
                {test_name, " : VC"}
            );

            check(
                h.dest_x === expected_dest.x,
                {test_name, " : destination X"}
            );

            check(
                h.dest_y === expected_dest.y,
                {test_name, " : destination Y"}
            );

            check(
                h.src_x === DUT_COORD.x,
                {test_name, " : source X"}
            );

            check(
                h.src_y === DUT_COORD.y,
                {test_name, " : source Y"}
            );

            check(
                h.msg_type === expected_msg,
                {test_name, " : message type"}
            );

            check(
                h.length === message_length(expected_msg),
                {test_name, " : length"}
            );

            check(
                int'(captured_tag) < N_OUTSTANDING,
                {test_name, " : tag in range"}
            );

            $display(
                "[INFO] %s : allocated tag = %0d",
                test_name,
                captured_tag
            );

            @(posedge clk);
            #TSETTLE;

        end

    endtask

    //=====================================================================
    // Send payload flit
    //=====================================================================

    task automatic send_payload(
        input logic [FLIT_WIDTH-1:0] data,
        input flit_type_e expected_type,
        input string test_name
    );

        begin

            @(negedge clk);

            tx_payload_data = data;
            tx_payload_valid = 1'b1;

            #TSETTLE;

            while (!(noc_tx_valid && noc_tx_ready)) begin
                @(negedge clk);
                #TSETTLE;
            end

            check(
                noc_tx_flit.flit_type === expected_type,
                {test_name, " : flit type"}
            );

            check(
                noc_tx_flit.flit_data === data,
                {test_name, " : data"}
            );

            @(posedge clk);
            #TSETTLE;

            tx_payload_valid = 1'b0;

        end

    endtask

    //=====================================================================
    // N-8.1 store-and-forward: supply one payload flit to the NI buffer
    // (handshake on tx_payload_ready; nothing reaches the NoC yet).
    //=====================================================================

    task automatic fill_payload(
        input logic [FLIT_WIDTH-1:0] data
    );

        begin

            @(negedge clk);

            tx_payload_data = data;
            tx_payload_valid = 1'b1;

            #TSETTLE;

            while (!tx_payload_ready) begin
                @(negedge clk);
                #TSETTLE;
            end

            @(posedge clk);
            #TSETTLE;

            tx_payload_valid = 1'b0;

        end

    endtask

    //=====================================================================
    // N-8.1: check one transmitted payload flit (from the NI buffer)
    //=====================================================================

    task automatic check_tx_flit(
        input logic [FLIT_WIDTH-1:0] data,
        input flit_type_e expected_type,
        input string test_name
    );

        begin

            while (!(noc_tx_valid && noc_tx_ready)) begin
                @(negedge clk);
                #TSETTLE;
            end

            check(
                noc_tx_flit.flit_type === expected_type,
                {test_name, " : flit type"}
            );

            check(
                noc_tx_flit.flit_data === data,
                {test_name, " : data"}
            );

            @(posedge clk);
            #TSETTLE;

        end

    endtask

    //=====================================================================
    // Drive RX HEAD
    //=====================================================================

    task automatic drive_rx_head(
        input coord_t source_coord,
        input msg_type_e message_type,
        input logic [10:0] control_value,
        input flit_type_e flit_type_value
    );

        begin

            @(negedge clk);

            noc_rx_flit.flit_data =
                make_head(
                    DUT_COORD,
                    source_coord,
                    message_type,
                    message_length(message_type),
                    control_value
                );

            noc_rx_flit.flit_type = flit_type_value;

            noc_rx_flit.vc_id =
                message_to_vc(message_type);

            noc_rx_valid = 1'b1;

            #TSETTLE;

            while (!noc_rx_ready) begin
                @(negedge clk);
                #TSETTLE;
            end

        end

    endtask

    //=====================================================================
    // Consume RX transfer
    //=====================================================================

    task automatic consume_rx;

        begin
            @(posedge clk);
            #TSETTLE;

            noc_rx_valid = 1'b0;
        end

    endtask

    //=====================================================================
    // Send memory read request
    //=====================================================================

    task automatic send_read_request(
        input coord_t destination,
        input string name,
        output txn_tag_t allocated_tag
    );

        begin

            send_request(
                destination,
                MSG_MEM_RD_REQ,
                11'h000
            );

            // N-8.1: payload is buffered before the HEAD is injected.
            fill_payload(32'h1234_5678);

            check_tx_head(
                destination,
                MSG_MEM_RD_REQ,
                name,
                allocated_tag
            );

            check_tx_flit(
                32'h1234_5678,
                FLIT_TAIL,
                {name, " payload"}
            );

            check(
                tx_busy === 1'b0,
                {name, " : TX complete"}
            );

        end

    endtask

    //=====================================================================
    // Send memory write request
    //=====================================================================

    task automatic send_write_request(
        input coord_t destination,
        input string name,
        output txn_tag_t allocated_tag
    );

        logic [10:0] control_value;

        begin

            control_value = '0;
            control_value[10:7] = 4'b1111;

            send_request(
                destination,
                MSG_MEM_WR_REQ,
                control_value
            );

            // N-8.1: payload is buffered before the HEAD is injected.
            fill_payload(32'h0000_1000);
            fill_payload(32'hCAFE_BABE);

            check_tx_head(
                destination,
                MSG_MEM_WR_REQ,
                name,
                allocated_tag
            );

            check_tx_flit(
                32'h0000_1000,
                FLIT_BODY,
                {name, " address"}
            );

            check_tx_flit(
                32'hCAFE_BABE,
                FLIT_TAIL,
                {name, " data"}
            );

            check(
                tx_busy === 1'b0,
                {name, " : TX complete"}
            );

        end

    endtask

    //=====================================================================
    // Send memory read response
    //=====================================================================

    task automatic send_read_response(
        input coord_t source_coord,
        input txn_tag_t response_tag,
        input string name
    );

        logic [10:0] control_value;

        begin

            control_value = '0;

            control_value[TXN_TAG_WIDTH-1:0] =
                response_tag;

            //-----------------------------------------------------------------
            // HEAD
            //-----------------------------------------------------------------

            drive_rx_head(
                source_coord,
                MSG_MEM_RD_RESP,
                control_value,
                FLIT_HEAD
            );

            check(
                rx_head_valid === 1'b1,
                {name, " : response HEAD accepted"}
            );

            check(
                rx_msg_type === MSG_MEM_RD_RESP,
                {name, " : response type"}
            );

            check(
                get_txn_tag(rx_control) === response_tag,
                {name, " : response tag"}
            );

            check(
                rx_protocol_error === 1'b0,
                {name, " : no protocol error"}
            );

            consume_rx;

            //-----------------------------------------------------------------
            // PAYLOAD / TAIL
            //-----------------------------------------------------------------

            @(negedge clk);

            noc_rx_flit.flit_data = 32'hDEAD_BEEF;
            noc_rx_flit.flit_type = FLIT_TAIL;
            noc_rx_flit.vc_id = VC_RESPONSE;

            noc_rx_valid = 1'b1;

            #TSETTLE;

            check(
                rx_payload_valid === 1'b1,
                {name, " : response data valid"}
            );

            check(
                rx_payload_data === 32'hDEAD_BEEF,
                {name, " : response data"}
            );

            check(
                rx_payload_last === 1'b1,
                {name, " : response data last"}
            );

            consume_rx;

            // Allow transaction-table deallocation to update.
            @(posedge clk);
            #TSETTLE;

        end

    endtask

    //=====================================================================
    // T01 RESET
    //=====================================================================

    task automatic test_reset;

        begin

            $display("");
            $display("========== T01 RESET ==========");

            reset_dut;

            check(
                tx_ready === 1'b1,
                "TX ready after reset"
            );

            check(
                tx_busy === 1'b0,
                "TX idle after reset"
            );

            check(
                rx_busy === 1'b0,
                "RX idle after reset"
            );

            check(
                noc_tx_valid === 1'b0,
                "No TX flit after reset"
            );

        end

    endtask

    //=====================================================================
    // T02 BASIC TX + TAG
    //=====================================================================

    task automatic test_basic_tx;

        txn_tag_t tag;

        begin

            $display("");
            $display("========== T02 BASIC TX + TAG ==========");

            reset_dut;

            send_write_request(
                tile_to_coord(TILE_MEMORY),
                "T02",
                tag
            );

            check(
                tag < N_OUTSTANDING,
                "T02 generated tag is valid"
            );

            // N_OUTSTANDING = 2.
            // One transaction occupies one slot, so one slot remains free.
            check(
                tx_ready === 1'b1,
                "T02 one slot remains available"
            );

        end

    endtask

    //=====================================================================
    // T03 TWO OUTSTANDING
    //=====================================================================

    task automatic test_two_outstanding;

        begin

            $display("");
            $display("========== T03 TWO OUTSTANDING ==========");

            reset_dut;

            send_read_request(
                tile_to_coord(TILE_CPU1),
                "T03 TX0",
                tag0
            );

            send_read_request(
                tile_to_coord(TILE_MEMORY),
                "T03 TX1",
                tag1
            );

            check(
                tag0 != tag1,
                "T03 two outstanding transactions have unique tags"
            );

            check(
                tx_ready === 1'b0,
                "T03 TX blocked when two slots are occupied"
            );

        end

    endtask

    //=====================================================================
    // T04 THIRD REQUEST BLOCKED
    //=====================================================================

    task automatic test_third_blocked;

        begin

            $display("");
            $display("========== T04 THIRD REQUEST BLOCKED ==========");

            @(negedge clk);

            tx_dest_coord =
                tile_to_coord(TILE_ROT);

            tx_msg_type =
                MSG_MEM_RD_REQ;

            tx_control = 11'h000;

            tx_valid = 1'b1;

            #TSETTLE;

            check(
                tx_ready === 1'b0,
                "T04 third transaction is blocked"
            );

            check(
                noc_tx_valid === 1'b0,
                "T04 no third packet injected"
            );

            tx_valid = 1'b0;

        end

    endtask

    //=====================================================================
    // T05 RESPONSE MATCHING / OUT-OF-ORDER RESPONSE
    //=====================================================================

    task automatic test_response_matching;

        begin

            $display("");
            $display("========== T05 RESPONSE MATCHING ==========");

            //-----------------------------------------------------------------
            // TX1 response arrives first.
            //-----------------------------------------------------------------

            send_read_response(
                tile_to_coord(TILE_MEMORY),
                tag1,
                "T05 TX1 RESPONSE"
            );

            repeat (2)
                @(posedge clk);

            #TSETTLE;

            check(
                tx_ready === 1'b1,
                "T05 one slot freed after TX1 response"
            );

            //-----------------------------------------------------------------
            // TX0 response arrives second.
            //-----------------------------------------------------------------

            send_read_response(
                tile_to_coord(TILE_CPU1),
                tag0,
                "T05 TX0 RESPONSE"
            );

            repeat (2)
                @(posedge clk);

            #TSETTLE;

            check(
                tx_ready === 1'b1,
                "T05 both slots are free"
            );

            check(
                rx_busy === 1'b0,
                "T05 RX idle after responses"
            );

        end

    endtask

    //=====================================================================
    // T06 WRONG RESPONSE SOURCE
    //=====================================================================

    task automatic test_wrong_source;

        txn_tag_t tag;
        logic [10:0] control_value;

        begin

            $display("");
            $display("========== T06 WRONG RESPONSE SOURCE ==========");

            reset_dut;

            send_read_request(
                tile_to_coord(TILE_CPU1),
                "T06 REQUEST",
                tag
            );

            control_value = '0;

            control_value[TXN_TAG_WIDTH-1:0] =
                tag;

            drive_rx_head(
                tile_to_coord(TILE_MEMORY),
                MSG_MEM_RD_RESP,
                control_value,
                FLIT_HEAD
            );

            check(
                rx_protocol_error === 1'b1,
                "T06 wrong response source rejected"
            );

            check(
                rx_head_valid === 1'b0,
                "T06 wrong response source not delivered"
            );

            check(
                noc_rx_ready === 1'b1,
                "T06 wrong response source consumed"
            );

            consume_rx;

            //-----------------------------------------------------------------
            // N-8.1 (spec sec.4 F10): a rejected HEAD opens a wormhole that only
            // its TAIL closes (mirrors allocator.sv). The pre-N-8.1 test sent
            // the rejected HEAD alone - a stream no router can produce. The
            // rejected packet's TAIL is now sent; it must be consumed, not
            // delivered, and the NI must return to IDLE.
            //-----------------------------------------------------------------

            @(negedge clk);

            noc_rx_flit.flit_data = 32'hBAD0_BAD0;
            noc_rx_flit.flit_type = FLIT_TAIL;
            noc_rx_flit.vc_id     = VC_RESPONSE;
            noc_rx_valid          = 1'b1;

            #TSETTLE;

            check(
                (noc_rx_ready === 1'b1) && (rx_payload_valid === 1'b0),
                "T06 rejected packet TAIL discarded (N-8.1)"
            );

            consume_rx;

            check(
                rx_busy === 1'b0,
                "T06 NI idle after discarding rejected packet (N-8.1)"
            );

            send_read_response(
                tile_to_coord(TILE_CPU1),
                tag,
                "T06 CORRECT RESPONSE"
            );

            repeat (2)
                @(posedge clk);

            #TSETTLE;

            check(
                tx_ready === 1'b1,
                "T06 transaction freed by correct response"
            );

        end

    endtask

    //=====================================================================
    // T07 WRONG RESPONSE TYPE
    //=====================================================================

    task automatic test_wrong_type;

        txn_tag_t tag;
        logic [10:0] control_value;

        begin

            $display("");
            $display("========== T07 WRONG RESPONSE TYPE ==========");

            reset_dut;

            send_read_request(
                tile_to_coord(TILE_CPU1),
                "T07 REQUEST",
                tag
            );

            control_value = '0;

            control_value[TXN_TAG_WIDTH-1:0] =
                tag;

            drive_rx_head(
                tile_to_coord(TILE_CPU1),
                MSG_MEM_WR_RESP,
                control_value,
                FLIT_HEAD_TAIL
            );

            check(
                rx_protocol_error === 1'b1,
                "T07 wrong response type rejected"
            );

            check(
                rx_head_valid === 1'b0,
                "T07 wrong response type not delivered"
            );

            consume_rx;

            send_read_response(
                tile_to_coord(TILE_CPU1),
                tag,
                "T07 CORRECT RESPONSE"
            );

            repeat (2)
                @(posedge clk);

            #TSETTLE;

            check(
                tx_ready === 1'b1,
                "T07 transaction freed"
            );

        end

    endtask

    //=====================================================================
    // T08 SLOT REUSE
    //=====================================================================

    task automatic test_slot_reuse;

        txn_tag_t old_tag;
        txn_tag_t new_tag;

        begin

            $display("");
            $display("========== T08 SLOT REUSE ==========");

            reset_dut;

            //-----------------------------------------------------------------
            // First transaction
            //-----------------------------------------------------------------

            send_read_request(
                tile_to_coord(TILE_CPU1),
                "T08 FIRST",
                old_tag
            );

            //-----------------------------------------------------------------
            // Complete first transaction
            //-----------------------------------------------------------------

            send_read_response(
                tile_to_coord(TILE_CPU1),
                old_tag,
                "T08 FIRST RESPONSE"
            );

            repeat (2)
                @(posedge clk);

            #TSETTLE;

            check(
                tx_ready === 1'b1,
                "T08 slot available after response"
            );

            //-----------------------------------------------------------------
            // New transaction
            //-----------------------------------------------------------------

            send_read_request(
                tile_to_coord(TILE_MEMORY),
                "T08 SECOND",
                new_tag
            );

            check(
                int'(new_tag) < N_OUTSTANDING,
                "T08 new transaction received valid tag"
            );

            //-----------------------------------------------------------------
            // M10 allocates the lowest-numbered free slot.
            //-----------------------------------------------------------------

            check(
                new_tag === old_tag,
                "T08 freed slot reused"
            );

            //-----------------------------------------------------------------
            // Complete second transaction
            //-----------------------------------------------------------------

            send_read_response(
                tile_to_coord(TILE_MEMORY),
                new_tag,
                "T08 SECOND RESPONSE"
            );

            repeat (2)
                @(posedge clk);

            #TSETTLE;

            check(
                tx_ready === 1'b1,
                "T08 all slots free"
            );

        end

    endtask

    //=====================================================================
    // T09 ATTESTATION RX
    //=====================================================================

    task automatic test_attestation_rx;

        begin

            $display("");
            $display("========== T09 ATTESTATION RX ==========");

            reset_dut;

            drive_rx_head(
                tile_to_coord(TILE_ROT),
                MSG_ATTEST_GRANT,
                11'h055,
                FLIT_HEAD_TAIL
            );

            check(
                rx_head_valid === 1'b1,
                "T09 attestation packet accepted"
            );

            check(
                rx_src_coord === tile_to_coord(TILE_ROT),
                "T09 source correct"
            );

            check(
                rx_dest_coord === DUT_COORD,
                "T09 destination correct"
            );

            check(
                rx_msg_type === MSG_ATTEST_GRANT,
                "T09 message type correct"
            );

            check(
                rx_control === 11'h055,
                "T09 control correct"
            );

            check(
                rx_protocol_error === 1'b0,
                "T09 no protocol error"
            );

            consume_rx;

            repeat (2)
                @(posedge clk);

            #TSETTLE;

            check(
                rx_busy === 1'b0,
                "T09 RX returns idle"
            );

        end

    endtask

    //=====================================================================
    // MAIN
    //=====================================================================

    initial begin

        $display("");
        $display("============================================================");
        $display("             M10 NETWORK INTERFACE TESTBENCH");
        $display("============================================================");

        $display(
            "N_OUTSTANDING = %0d",
            N_OUTSTANDING
        );

        $display(
            "TXN_TAG_WIDTH  = %0d",
            TXN_TAG_WIDTH
        );

        $display(
            "MAC_ENABLE     = %0d",
            MAC_ENABLE
        );

        $display("============================================================");

        test_reset;

        test_basic_tx;

        test_two_outstanding;

        test_third_blocked;

        test_response_matching;

        test_wrong_source;

        test_wrong_type;

        test_slot_reuse;

        test_attestation_rx;

        repeat (3)
            @(posedge clk);

        $display("");
        $display("============================================================");
        $display("                    M10 SUMMARY");
        $display("============================================================");

        $display(
            "Checks : %0d",
            checks
        );

        $display(
            "Errors : %0d",
            errors
        );

        if (errors == 0)
            $display("RESULT : PASS");
        else
            $display("RESULT : FAIL");

        $display("============================================================");

        if (errors == 0)
            $finish;
        else
            $fatal(1, "M10 testbench FAILED");

    end

endmodule