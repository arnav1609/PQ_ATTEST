`timescale 1ns/1ps
//=============================================================================
// PQ-Attest NoC : M8+M9+M10+M11 CURRENT-SOURCE INTEGRATION TB
//
// Purpose:
//   Integrates the CURRENT RTL boundary:
//     M11 noc_addr_decoder
//        -> M10 noc_network_interface
//        -> M8 noc_router (which contains M9 credit control)
//        -> M8 noc_router
//        -> M10 noc_network_interface
//
// This is NOT the old tb6_1.sv copied unchanged.
// Important fixes versus tb6_1:
//   1. M9 credit_return is wired on the router link.
//   2. M11 is instantiated and its remote decode drives NI destination.
//   3. No testbench drive is applied to NI output noc_rx_ready.
//   4. The adjacent pair is CPU0=(0,0) <-> CPU1=(1,0).
//
// N-6 REBUILD (7c contract, NO bypasses):
//   - NI noc_tx_ready      <- router in_ready_local  (masked while the stress
//                             injector owns the LOCAL port)
//   - router out_ready_local <- NI noc_rx_ready
//   - router credit_return <- neighbour router credit_out PORT (no hierarchy)
//   - tile-side rx*_ready is a TB variable (default 1) so T11/T12 can hold it 0
//   - stress injectors honour in_ready_local (no peeking at full flags)
//   - persistent per-router flit-conservation counters (handshakes only)
//
// M9 credit return model:
//   For EAST/WEST, the downstream router's FIFO dequeue-credit pulse is
//   returned to the upstream router. The current noc_router datapath exposes
//   credit_<port>_vc<vc> as the dequeue pulse source.
//=============================================================================

module tb_n6_two_tile_stress;

    import noc_pkg::*;

    localparam coord_t CPU0_COORD = tile_to_coord(TILE_CPU0);
    localparam coord_t CPU1_COORD = tile_to_coord(TILE_CPU1);

    localparam logic [31:0] TEST_DATA = 32'hCAFE_BABE;

    // Remote address targeting CPU1. REMOTE_BASE carries the remote-region
    // encoding; tile selector is the frozen address[27:24] field.
    localparam logic [31:0] CPU1_REMOTE_ADDR =
        REMOTE_BASE |
        (logic'(TILE_CPU1) << TILE_SEL_LSB) |
        32'h0000_0100;

    localparam int TIMEOUT_CYCLES = 5000;

    logic clk, rst;
    integer checks, errors, cycle_count;

    //--------------------------------------------------------------------------
    // M11 decoder -> CPU0 NI destination
    //--------------------------------------------------------------------------

    logic [31:0] dec0_addr;
    logic dec0_addr_valid;
    logic dec0_is_local, dec0_bus_error;
    local_target_e dec0_local_sel;
    addr_decode_t dec0_remote;

    noc_addr_decoder #(
        .LOCAL_TILE_ID(TILE_CPU0)
    ) dec0 (
        .addr(dec0_addr),
        .addr_valid(dec0_addr_valid),
        .is_local(dec0_is_local),
        .local_sel(dec0_local_sel),
        .remote(dec0_remote),
        .bus_error(dec0_bus_error)
    );

    //--------------------------------------------------------------------------
    // M11 decoder -> CPU1 NI destination
    //--------------------------------------------------------------------------

    logic [31:0] dec1_addr;
    logic dec1_addr_valid;
    logic dec1_is_local, dec1_bus_error;
    local_target_e dec1_local_sel;
    addr_decode_t dec1_remote;

    noc_addr_decoder #(
        .LOCAL_TILE_ID(TILE_CPU1)
    ) dec1 (
        .addr(dec1_addr),
        .addr_valid(dec1_addr_valid),
        .is_local(dec1_is_local),
        .local_sel(dec1_local_sel),
        .remote(dec1_remote),
        .bus_error(dec1_bus_error)
    );

    //--------------------------------------------------------------------------
    // NI0 / NI1 tile-side interfaces
    //--------------------------------------------------------------------------

    logic tx0_valid, tx0_ready;
    coord_t tx0_dest_coord;
    msg_type_e tx0_msg_type;
    logic [10:0] tx0_control;
    logic [FLIT_WIDTH-1:0] tx0_payload_data;
    logic tx0_payload_valid, tx0_payload_ready;
    logic [MAC_TAG_BITS-1:0] tx0_mac_tag;
    logic tx0_error;

    logic tx1_valid, tx1_ready;
    coord_t tx1_dest_coord;
    msg_type_e tx1_msg_type;
    logic [10:0] tx1_control;
    logic [FLIT_WIDTH-1:0] tx1_payload_data;
    logic tx1_payload_valid, tx1_payload_ready;
    logic [MAC_TAG_BITS-1:0] tx1_mac_tag;
    logic tx1_error;

    flit_t ni0_tx_flit, ni1_tx_flit;
    logic ni0_tx_valid, ni0_tx_ready;
    logic ni1_tx_valid, ni1_tx_ready;

    flit_t ni0_rx_flit, ni1_rx_flit;
    logic ni0_rx_valid, ni1_rx_valid;
    logic ni0_rx_ready, ni1_rx_ready;

    coord_t rx0_src_coord, rx0_dest_coord;
    msg_type_e rx0_msg_type;
    logic [10:0] rx0_control;
    logic [4:0] rx0_length;
    logic rx0_head_valid, rx0_payload_valid, rx0_payload_last, rx0_ready;
    logic [FLIT_WIDTH-1:0] rx0_payload_data;
    logic [MAC_TAG_BITS-1:0] rx0_mac_tag;
    logic rx0_mac_valid, rx0_protocol_error, rx0_length_error;
    logic tx0_busy, rx0_busy;

    coord_t rx1_src_coord, rx1_dest_coord;
    msg_type_e rx1_msg_type;
    logic [10:0] rx1_control;
    logic [4:0] rx1_length;
    logic rx1_head_valid, rx1_payload_valid, rx1_payload_last, rx1_ready;
    logic [FLIT_WIDTH-1:0] rx1_payload_data;
    logic [MAC_TAG_BITS-1:0] rx1_mac_tag;
    logic rx1_mac_valid, rx1_protocol_error, rx1_length_error;
    logic tx1_busy, rx1_busy;

    noc_network_interface #(.LOCAL_TILE_ID(TILE_CPU0), .WD_LIMIT(64)) ni0 (  // N-8.1: T11/T12 hold the tile 40 cycles = a LEGAL stall under W=64 (< W)
        .clk(clk), .rst(rst),
        .tx_valid(tx0_valid), .tx_ready(tx0_ready),
        .tx_dest_coord(tx0_dest_coord), .tx_msg_type(tx0_msg_type),
        .tx_control(tx0_control), .tx_payload_data(tx0_payload_data),
        .tx_payload_valid(tx0_payload_valid), .tx_payload_ready(tx0_payload_ready),
        .tx_mac_tag(tx0_mac_tag), .tx_error(tx0_error),
        .noc_tx_flit(ni0_tx_flit), .noc_tx_valid(ni0_tx_valid),
        .noc_tx_ready(ni0_tx_ready),
        .noc_rx_flit(ni0_rx_flit), .noc_rx_valid(ni0_rx_valid),
        .noc_rx_ready(ni0_rx_ready),
        .rx_src_coord(rx0_src_coord), .rx_dest_coord(rx0_dest_coord),
        .rx_msg_type(rx0_msg_type), .rx_control(rx0_control),
        .rx_length(rx0_length), .rx_head_valid(rx0_head_valid),
        .rx_payload_data(rx0_payload_data), .rx_payload_valid(rx0_payload_valid),
        .rx_payload_last(rx0_payload_last), .rx_ready(rx0_ready),
        .rx_mac_tag(rx0_mac_tag), .rx_mac_valid(rx0_mac_valid),
        .rx_protocol_error(rx0_protocol_error), .rx_length_error(rx0_length_error),
        .ni_status_clr(1'b0),   // N-8.1: report outputs left open in N-6
        .tx_busy(tx0_busy), .rx_busy(rx0_busy)
    );

    noc_network_interface #(.LOCAL_TILE_ID(TILE_CPU1), .WD_LIMIT(64)) ni1 (  // N-8.1: T11/T12 hold the tile 40 cycles = a LEGAL stall under W=64 (< W)
        .clk(clk), .rst(rst),
        .tx_valid(tx1_valid), .tx_ready(tx1_ready),
        .tx_dest_coord(tx1_dest_coord), .tx_msg_type(tx1_msg_type),
        .tx_control(tx1_control), .tx_payload_data(tx1_payload_data),
        .tx_payload_valid(tx1_payload_valid), .tx_payload_ready(tx1_payload_ready),
        .tx_mac_tag(tx1_mac_tag), .tx_error(tx1_error),
        .noc_tx_flit(ni1_tx_flit), .noc_tx_valid(ni1_tx_valid),
        .noc_tx_ready(ni1_tx_ready),
        .noc_rx_flit(ni1_rx_flit), .noc_rx_valid(ni1_rx_valid),
        .noc_rx_ready(ni1_rx_ready),
        .rx_src_coord(rx1_src_coord), .rx_dest_coord(rx1_dest_coord),
        .rx_msg_type(rx1_msg_type), .rx_control(rx1_control),
        .rx_length(rx1_length), .rx_head_valid(rx1_head_valid),
        .rx_payload_data(rx1_payload_data), .rx_payload_valid(rx1_payload_valid),
        .rx_payload_last(rx1_payload_last), .rx_ready(rx1_ready),
        .rx_mac_tag(rx1_mac_tag), .rx_mac_valid(rx1_mac_valid),
        .rx_protocol_error(rx1_protocol_error), .rx_length_error(rx1_length_error),
        .ni_status_clr(1'b0),   // N-8.1: report outputs left open in N-6
        .tx_busy(tx1_busy), .rx_busy(rx1_busy)
    );

    //--------------------------------------------------------------------------
    // Router physical links
    //--------------------------------------------------------------------------

    flit_t r0_in_north, r0_in_south, r0_in_east, r0_in_west, r0_in_local;
    logic r0_valid_north, r0_valid_south, r0_valid_east, r0_valid_west, r0_valid_local;
    flit_t r0_out_north, r0_out_south, r0_out_east, r0_out_west, r0_out_local;
    logic r0_out_valid_north, r0_out_valid_south, r0_out_valid_east, r0_out_valid_west, r0_out_valid_local;

    flit_t r1_in_north, r1_in_south, r1_in_east, r1_in_west, r1_in_local;
    logic r1_valid_north, r1_valid_south, r1_valid_east, r1_valid_west, r1_valid_local;
    flit_t r1_out_north, r1_out_south, r1_out_east, r1_out_west, r1_out_local;
    logic r1_out_valid_north, r1_out_valid_south, r1_out_valid_east, r1_out_valid_west, r1_out_valid_local;

    logic [NUM_VC-1:0] r0_credit_return [NUM_PORTS];
    logic [NUM_VC-1:0] r1_credit_return [NUM_PORTS];

    // 7c ports
    logic r0_in_ready_local, r1_in_ready_local;
    logic [NUM_VC-1:0] r0_credit_out [NUM_PORTS];
    logic [NUM_VC-1:0] r1_credit_out [NUM_PORTS];

    // N-6 stress injector and real downstream sink FIFOs.
    logic stress_r0_local_valid, stress_r1_local_valid;
    flit_t stress_r0_local_flit, stress_r1_local_flit;

    flit_t sink_flit_vc0, sink_flit_vc1, sink_flit_vc2;
    logic sink_wr_vc0, sink_wr_vc1, sink_wr_vc2;
    logic sink_rd_vc0, sink_rd_vc1, sink_rd_vc2;
    logic sink_empty_vc0, sink_empty_vc1, sink_empty_vc2;
    logic sink_full_vc0, sink_full_vc1, sink_full_vc2;
    logic [$clog2(VC0_DEPTH+1)-1:0] sink_occ_vc0, sink_free_vc0;
    logic [$clog2(VC1_DEPTH+1)-1:0] sink_occ_vc1, sink_free_vc1;
    logic [$clog2(VC2_DEPTH+1)-1:0] sink_occ_vc2, sink_free_vc2;
    logic sink_credit_vc0, sink_credit_vc1, sink_credit_vc2;

    integer stress_tx_count;

    // Persistent N-6 observation monitors. These are enabled BEFORE traffic
    // injection so one-cycle transfers cannot be missed by a late polling loop.
    logic t7_monitor_enable;
    logic t7_east_seen, t7_west_seen;
    integer t8_txc, t8_rxc;
    logic t8_monitor_enable;

    always @(posedge clk) begin
        if (rst) begin
            t7_east_seen <= 1'b0;
            t7_west_seen <= 1'b0;
            t8_txc <= 0;
            t8_rxc <= 0;
        end else begin
            if (t7_monitor_enable) begin
                if (r1_out_valid_local && ni1_rx_ready) t7_east_seen <= 1'b1;
                if (r0_out_valid_local && ni0_rx_ready) t7_west_seen <= 1'b1;
            end
            if (t8_monitor_enable) begin
                if (r0_out_valid_east) t8_txc <= t8_txc + 1;
                if (r1_out_valid_local && ni1_rx_ready) t8_rxc <= t8_rxc + 1;
            end
        end
    end

    noc_router r0 (
        .clk(clk), .rst(rst), .current_coord(CPU0_COORD),
        .in_flit_north(r0_in_north), .in_valid_north(r0_valid_north),
        .in_flit_south(r0_in_south), .in_valid_south(r0_valid_south),
        .in_flit_east(r0_in_east), .in_valid_east(r0_valid_east),
        .in_flit_west(r0_in_west), .in_valid_west(r0_valid_west),
        .in_flit_local(r0_in_local), .in_valid_local(r0_valid_local),
        .in_ready_local(r0_in_ready_local), .credit_out(r0_credit_out),
        .credit_return(r0_credit_return),
        .out_flit_north(r0_out_north), .out_valid_north(r0_out_valid_north),
        .out_flit_south(r0_out_south), .out_valid_south(r0_out_valid_south),
        .out_flit_east(r0_out_east), .out_valid_east(r0_out_valid_east),
        .out_flit_west(r0_out_west), .out_valid_west(r0_out_valid_west),
        .out_flit_local(r0_out_local), .out_valid_local(r0_out_valid_local),
        .out_ready_local(ni0_rx_ready)      // 7c: NI accepts LOCAL flit
    );

    noc_router r1 (
        .clk(clk), .rst(rst), .current_coord(CPU1_COORD),
        .in_flit_north(r1_in_north), .in_valid_north(r1_valid_north),
        .in_flit_south(r1_in_south), .in_valid_south(r1_valid_south),
        .in_flit_east(r1_in_east), .in_valid_east(r1_valid_east),
        .in_flit_west(r1_in_west), .in_valid_west(r1_valid_west),
        .in_flit_local(r1_in_local), .in_valid_local(r1_valid_local),
        .in_ready_local(r1_in_ready_local), .credit_out(r1_credit_out),
        .credit_return(r1_credit_return),
        .out_flit_north(r1_out_north), .out_valid_north(r1_out_valid_north),
        .out_flit_south(r1_out_south), .out_valid_south(r1_out_valid_south),
        .out_flit_east(r1_out_east), .out_valid_east(r1_out_valid_east),
        .out_flit_west(r1_out_west), .out_valid_west(r1_out_valid_west),
        .out_flit_local(r1_out_local), .out_valid_local(r1_out_valid_local),
        .out_ready_local(ni1_rx_ready)      // 7c: NI accepts LOCAL flit
    );

    // Local NI links.
    assign r0_in_local = stress_r0_local_valid ? stress_r0_local_flit : ni0_tx_flit;
    assign r0_valid_local = stress_r0_local_valid ? 1'b1 : ni0_tx_valid;
    assign ni0_tx_ready = r0_in_ready_local && !stress_r0_local_valid;
    assign ni0_rx_flit = r0_out_local;
    assign ni0_rx_valid = r0_out_valid_local;

    assign r1_in_local = stress_r1_local_valid ? stress_r1_local_flit : ni1_tx_flit;
    assign r1_valid_local = stress_r1_local_valid ? 1'b1 : ni1_tx_valid;
    assign ni1_tx_ready = r1_in_ready_local && !stress_r1_local_valid;
    assign ni1_rx_flit = r1_out_local;
    assign ni1_rx_valid = r1_out_valid_local;
    // rx0_ready / rx1_ready: TB variables, set in reset_dut, held low by T11/T12.

    // Adjacent EAST/WEST physical link.
    assign r0_in_east = r1_out_west;
    assign r0_valid_east = r1_out_valid_west;
    assign r1_in_west = r0_out_east;
    assign r1_valid_west = r0_out_valid_east;

    // Unused mesh directions.
    assign r0_in_north = '0;
    assign r0_in_south = '0;
    assign r0_in_west  = '0;
    assign r0_valid_north = 1'b0;
    assign r0_valid_south = 1'b0;
    assign r0_valid_west  = 1'b0;

    assign r1_in_north = '0;
    assign r1_in_south = '0;
    assign r1_in_east  = '0;
    assign r1_valid_north = 1'b0;
    assign r1_valid_south = 1'b0;
    assign r1_valid_east  = 1'b0;

    //--------------------------------------------------------------------------
    //==========================================================================
    // Real downstream VC FIFOs attached to R1 EAST.
    //==========================================================================
    always_comb begin
        sink_wr_vc0 = r1_out_valid_east && (r1_out_east.vc_id == VC_REQUEST);
        sink_wr_vc1 = r1_out_valid_east && (r1_out_east.vc_id == VC_RESPONSE);
        sink_wr_vc2 = r1_out_valid_east && (r1_out_east.vc_id == VC_ATTESTATION);
    end

    noc_fifo #(.DEPTH(VC0_DEPTH)) n6_sink_vc0 (
        .clk(clk), .rst(rst), .wr_flit(r1_out_east), .wr_en(sink_wr_vc0),
        .rd_en(sink_rd_vc0), .rd_flit(sink_flit_vc0), .empty(sink_empty_vc0),
        .full(sink_full_vc0), .occupancy(sink_occ_vc0), .free_slots(sink_free_vc0),
        .credit_valid(sink_credit_vc0));

    noc_fifo #(.DEPTH(VC1_DEPTH)) n6_sink_vc1 (
        .clk(clk), .rst(rst), .wr_flit(r1_out_east), .wr_en(sink_wr_vc1),
        .rd_en(sink_rd_vc1), .rd_flit(sink_flit_vc1), .empty(sink_empty_vc1),
        .full(sink_full_vc1), .occupancy(sink_occ_vc1), .free_slots(sink_free_vc1),
        .credit_valid(sink_credit_vc1));

    noc_fifo #(.DEPTH(VC2_DEPTH)) n6_sink_vc2 (
        .clk(clk), .rst(rst), .wr_flit(r1_out_east), .wr_en(sink_wr_vc2),
        .rd_en(sink_rd_vc2), .rd_flit(sink_flit_vc2), .empty(sink_empty_vc2),
        .full(sink_full_vc2), .occupancy(sink_occ_vc2), .free_slots(sink_free_vc2),
        .credit_valid(sink_credit_vc2));

    // M9 link credit return.
    //
    // The downstream router's credit_out port (one pulse per input-FIFO pop)
    // is the upstream router's credit_return. R1 EAST credit comes from the
    // real sink FIFOs above.
    //--------------------------------------------------------------------------
    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            r0_credit_return[p] = '0;
            r1_credit_return[p] = '0;
        end

        // 7c: neighbour credit_out PORT -> credit_return (no hierarchical taps).
        r0_credit_return[PORT_EAST] = r1_credit_out[PORT_WEST];
        r1_credit_return[PORT_WEST] = r0_credit_out[PORT_EAST];

        r1_credit_return[PORT_EAST][0] = sink_credit_vc0;
        r1_credit_return[PORT_EAST][1] = sink_credit_vc1;
        r1_credit_return[PORT_EAST][2] = sink_credit_vc2;
    end

    //==========================================================================
    // Persistent flit-conservation monitor (handshakes only, cleared by rst).
    //   R0 in : LOCAL in  + EAST in (= R1 WEST out)
    //   R0 out: LOCAL out + EAST out
    //   R1 in : LOCAL in  + WEST in (= R0 EAST out)
    //   R1 out: LOCAL out + WEST out + EAST out (to sink)
    // Link EAST/WEST is credit-based: every out_valid cycle is a transfer.
    // LOCAL is ready/valid: only valid && ready counts.
    //==========================================================================
    integer cn_r0_lin, cn_r1_lin, cn_r0_lout, cn_r1_lout;
    integer cn_r0_e, cn_r1_w, cn_r1_e;
    integer mux_collisions;
    integer rx1_head_hs, rx1_pay_hs, rx1_perr, rx0_perr;
    logic [31:0] rx1_pay_log [0:7];

    always @(posedge clk) begin
        if (rst) begin
            cn_r0_lin <= 0; cn_r1_lin <= 0; cn_r0_lout <= 0; cn_r1_lout <= 0;
            cn_r0_e <= 0; cn_r1_w <= 0; cn_r1_e <= 0;
            rx1_head_hs <= 0; rx1_pay_hs <= 0; rx1_perr <= 0; rx0_perr <= 0;
        end else begin
            if (r0_valid_local && r0_in_ready_local)  cn_r0_lin  <= cn_r0_lin + 1;
            if (r1_valid_local && r1_in_ready_local)  cn_r1_lin  <= cn_r1_lin + 1;
            if (r0_out_valid_local && ni0_rx_ready)   cn_r0_lout <= cn_r0_lout + 1;
            if (r1_out_valid_local && ni1_rx_ready)   cn_r1_lout <= cn_r1_lout + 1;
            if (r0_out_valid_east)                    cn_r0_e    <= cn_r0_e + 1;
            if (r1_out_valid_west)                    cn_r1_w    <= cn_r1_w + 1;
            if (r1_out_valid_east)                    cn_r1_e    <= cn_r1_e + 1;

            if (rx1_head_valid && rx1_ready)          rx1_head_hs <= rx1_head_hs + 1;
            if (rx1_payload_valid && rx1_ready) begin
                if (rx1_pay_hs < 8) rx1_pay_log[rx1_pay_hs] <= rx1_payload_data;
                rx1_pay_hs <= rx1_pay_hs + 1;
            end
            if (rx1_protocol_error) rx1_perr <= rx1_perr + 1;
            if (rx0_protocol_error) rx0_perr <= rx0_perr + 1;
        end
    end

    // The stress injector and the NI must never drive R0/R1 LOCAL together.
    always @(posedge clk) begin
        if (!rst && ((stress_r0_local_valid && ni0_tx_valid) ||
                     (stress_r1_local_valid && ni1_tx_valid)))
            mux_collisions <= mux_collisions + 1;
    end

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (rst) cycle_count <= 0;
        else     cycle_count <= cycle_count + 1;
    end

    //--------------------------------------------------------------------------
    // Checks
    //--------------------------------------------------------------------------

    task automatic check(input logic condition, input string message);
        begin
            checks++;
            if (condition)
                $display("[PASS] %s", message);
            else begin
                errors++;
                $display("[FAIL] %s", message);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Reset
    //--------------------------------------------------------------------------

    task automatic reset_dut;
        begin
            rst = 1'b1;

            tx0_valid = 0; tx0_dest_coord = '0; tx0_msg_type = MSG_MEM_RD_REQ;
            tx0_control = '0; tx0_payload_data = '0; tx0_payload_valid = 0;
            tx0_mac_tag = '0;

            tx1_valid = 0; tx1_dest_coord = '0; tx1_msg_type = MSG_MEM_RD_REQ;
            tx1_control = '0; tx1_payload_data = '0; tx1_payload_valid = 0;
            tx1_mac_tag = '0;

            dec0_addr = '0; dec0_addr_valid = 1'b0;
            dec1_addr = '0; dec1_addr_valid = 1'b0;

            rx0_ready = 1'b1;
            rx1_ready = 1'b1;

            repeat (5) @(posedge clk);
            rst = 1'b0;
            repeat (2) @(posedge clk);
            cycle_count = 0;
        end
    endtask

    //--------------------------------------------------------------------------
    // M11 decode helper.
    //--------------------------------------------------------------------------

    task automatic decode_cpu0_destination(input logic [31:0] addr);
        begin
            @(negedge clk);
            dec0_addr = addr;
            dec0_addr_valid = 1'b1;
            #1;
            check(dec0_bus_error == 1'b0, "M11 CPU0 address has no bus error");
            check(dec0_is_local == 1'b0, "M11 CPU0 address is remote");
            check(dec0_remote.valid == 1'b1, "M11 CPU0 remote decode valid");
            check(dec0_remote.coord == CPU1_COORD, "M11 CPU0 remote destination = CPU1");
            tx0_dest_coord = dec0_remote.coord;
            dec0_addr_valid = 1'b0;
        end
    endtask

    task automatic decode_cpu1_destination(input logic [31:0] addr);
        begin
            @(negedge clk);
            dec1_addr = addr;
            dec1_addr_valid = 1'b1;
            #1;
            check(dec1_bus_error == 1'b0, "M11 CPU1 address has no bus error");
            check(dec1_is_local == 1'b0, "M11 CPU1 address is remote");
            check(dec1_remote.valid == 1'b1, "M11 CPU1 remote decode valid");
            check(dec1_remote.coord == CPU0_COORD, "M11 CPU1 remote destination = CPU0");
            tx1_dest_coord = dec1_remote.coord;
            dec1_addr_valid = 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // CPU0 write -> CPU1 -> response
    //--------------------------------------------------------------------------

    task automatic test_write;
        logic [31:0] received_address, received_data;
        begin
            $display("\n=== T1 M11 -> M10 -> M8/M9 -> M10 WRITE ===");
            reset_dut;

            fork
                begin
                    wait (rx1_head_valid);
                    check(rx1_msg_type == MSG_MEM_WR_REQ, "CPU1 received MEM_WR_REQ");
                    check(rx1_src_coord == CPU0_COORD, "write source = CPU0");
                    check(rx1_dest_coord == CPU1_COORD, "write destination = CPU1");
                    check(rx1_protocol_error == 1'b0, "CPU1 write protocol valid");

                    while (!rx1_payload_valid) @(negedge clk);
                    #1;
                    received_address = rx1_payload_data;
                    check(rx1_payload_last == 1'b0, "write address is BODY");

                    @(negedge clk);
                    while (!rx1_payload_valid) @(negedge clk);
                    #1;
                    received_data = rx1_payload_data;
                    check(rx1_payload_last == 1'b1, "write data is TAIL");

                    @(negedge clk);
                    tx1_dest_coord = CPU0_COORD;
                    tx1_msg_type = MSG_MEM_WR_RESP;
                    tx1_control = '0;
                    tx1_control = set_txn_tag(tx1_control, get_txn_tag(rx1_control));
                    tx1_valid = 1'b1;
                    while (!tx1_ready) @(negedge clk);
                    @(posedge clk); #1; tx1_valid = 1'b0;
                    wait (!tx1_busy);
                end

                begin
                    decode_cpu0_destination(CPU1_REMOTE_ADDR);

                    @(negedge clk);
                    tx0_msg_type = MSG_MEM_WR_REQ;
                    tx0_control = '0;
                    tx0_control[10:7] = 4'b1111;
                    tx0_valid = 1'b1;
                    while (!tx0_ready) @(negedge clk);
                    @(posedge clk); #1; tx0_valid = 1'b0;

                    @(negedge clk);
                    tx0_payload_data = CPU1_REMOTE_ADDR;
                    tx0_payload_valid = 1'b1;
                    while (!tx0_payload_ready) @(negedge clk);
                    @(posedge clk); #1; tx0_payload_valid = 1'b0;

                    @(negedge clk);
                    tx0_payload_data = TEST_DATA;
                    tx0_payload_valid = 1'b1;
                    while (!tx0_payload_ready) @(negedge clk);
                    @(posedge clk); #1; tx0_payload_valid = 1'b0;

                    wait (!tx0_busy);
                end

                begin
                    wait (rx0_head_valid);
                    check(rx0_msg_type == MSG_MEM_WR_RESP, "CPU0 received MEM_WR_RESP");
                    check(rx0_src_coord == CPU1_COORD, "write response source = CPU1");
                    check(rx0_dest_coord == CPU0_COORD, "write response destination = CPU0");
                    check(rx0_protocol_error == 1'b0, "CPU0 write response protocol valid");
                end
            join

            check(received_address == CPU1_REMOTE_ADDR, "CPU1 received decoded remote address");
            check(received_data == TEST_DATA, "CPU1 received correct write data");
        end
    endtask

    //--------------------------------------------------------------------------
    // CPU0 read -> CPU1 -> response
    //--------------------------------------------------------------------------

    task automatic test_read;
        begin
            $display("\n=== T2 M11 -> M10 -> M8/M9 -> M10 READ ===");
            reset_dut;

            fork
                begin
                    wait (rx1_head_valid);
                    check(rx1_msg_type == MSG_MEM_RD_REQ, "CPU1 received MEM_RD_REQ");
                    check(rx1_src_coord == CPU0_COORD, "read source = CPU0");
                    check(rx1_dest_coord == CPU1_COORD, "read destination = CPU1");

                    while (!rx1_payload_valid) @(negedge clk);
                    #1;
                    check(rx1_payload_data == CPU1_REMOTE_ADDR, "read address correct");
                    check(rx1_payload_last == 1'b1, "read address is TAIL");

                    @(negedge clk);
                    tx1_dest_coord = CPU0_COORD;
                    tx1_msg_type = MSG_MEM_RD_RESP;
                    tx1_control = set_txn_tag('0, get_txn_tag(rx1_control));
                    tx1_valid = 1'b1;
                    while (!tx1_ready) @(negedge clk);
                    @(posedge clk); #1; tx1_valid = 1'b0;

                    @(negedge clk);
                    tx1_payload_data = TEST_DATA;
                    tx1_payload_valid = 1'b1;
                    while (!tx1_payload_ready) @(negedge clk);
                    @(posedge clk); #1; tx1_payload_valid = 1'b0;
                    wait (!tx1_busy);
                end

                begin
                    decode_cpu0_destination(CPU1_REMOTE_ADDR);

                    @(negedge clk);
                    tx0_msg_type = MSG_MEM_RD_REQ;
                    tx0_control = '0;
                    tx0_valid = 1'b1;
                    while (!tx0_ready) @(negedge clk);
                    @(posedge clk); #1; tx0_valid = 1'b0;

                    @(negedge clk);
                    tx0_payload_data = CPU1_REMOTE_ADDR;
                    tx0_payload_valid = 1'b1;
                    while (!tx0_payload_ready) @(negedge clk);
                    @(posedge clk); #1; tx0_payload_valid = 1'b0;
                    wait (!tx0_busy);
                end

                begin
                    wait (rx0_head_valid);
                    check(rx0_msg_type == MSG_MEM_RD_RESP, "CPU0 received MEM_RD_RESP");
                    check(rx0_src_coord == CPU1_COORD, "read response source = CPU1");
                    check(rx0_dest_coord == CPU0_COORD, "read response destination = CPU0");
                    while (!rx0_payload_valid) @(negedge clk);
                    #1;
                    check(rx0_payload_data == TEST_DATA, "read-back data correct");
                    check(rx0_payload_last == 1'b1, "read response payload is TAIL");
                end
            join
        end
    endtask

    //--------------------------------------------------------------------------
    // M11 negative/control checks
    //--------------------------------------------------------------------------

    task automatic test_decoder_contract;
        begin
            $display("\n=== T3 M11 decoder contract ===");
            reset_dut;

            @(negedge clk);
            dec0_addr = CPU1_REMOTE_ADDR;
            dec0_addr_valid = 1'b1;
            #1;
            check((dec0_is_local + dec0_remote.valid + dec0_bus_error) == 1,
                  "M11 exactly-one decode contract");

            dec0_addr_valid = 1'b0;
            #1;
            check(dec0_is_local == 1'b0 && dec0_remote.valid == 1'b0 &&
                  dec0_bus_error == 1'b0,
                  "M11 invalid address-valid clears outputs");
        end
    endtask

    //--------------------------------------------------------------------------
    //==========================================================================
    // N-6 stress helpers
    //==========================================================================
    function automatic flit_t make_stress_flit(
        input int dx, input int dy, input flit_type_e ft,
        input int vc, input logic [15:0] tag
    );
        flit_t f;
        begin
            f = '0;
            f.flit_data = '0;
            f.flit_data[31:29] = dx[2:0];
            f.flit_data[28:26] = dy[2:0];
            f.flit_data[25:23] = 3'd0;
            f.flit_data[22:20] = 3'd0;
            f.flit_data[19:16] = MSG_MEM_RD_REQ;
            f.flit_data[15:11] = 5'd1;
            f.flit_data[15:0] = tag;
            f.flit_type = ft;
            f.vc_id = vc[VC_ID_WIDTH-1:0];
            return f;
        end
    endfunction

    task automatic clear_stress;
        begin
            stress_r0_local_valid = 1'b0;
            stress_r1_local_valid = 1'b0;
            stress_r0_local_flit = '0;
            stress_r1_local_flit = '0;
            sink_rd_vc0 = 1'b0;
            sink_rd_vc1 = 1'b0;
            sink_rd_vc2 = 1'b0;
        end
    endtask

    // 7c: drive valid+flit at negedge, hold until in_ready_local is seen.
    // in_ready_local depends only on registered full flags and the held flit's
    // vc_id, so its negedge value equals its value at the next posedge.
    task automatic inject_r0(input flit_t f);
        begin
            @(negedge clk);
            stress_r0_local_flit = f;
            stress_r0_local_valid = 1'b1;
            #1;
            while (!r0_in_ready_local) begin @(negedge clk); #1; end
            @(posedge clk); #1;
            stress_r0_local_valid = 1'b0;
            stress_r0_local_flit = '0;
            stress_tx_count++;
        end
    endtask

    task automatic inject_r1(input flit_t f);
        begin
            @(negedge clk);
            stress_r1_local_flit = f;
            stress_r1_local_valid = 1'b1;
            #1;
            while (!r1_in_ready_local) begin @(negedge clk); #1; end
            @(posedge clk); #1;
            stress_r1_local_valid = 1'b0;
            stress_r1_local_flit = '0;
        end
    endtask

    task automatic wait_r0_east_zero;
        integer guard;
        begin
            guard = 0;
            while ((r0.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] != 0) &&
                   guard < 500) begin
                @(posedge clk);
                guard++;
            end
            check(guard < 500, "N-6 R0 EAST request credit reaches zero");
        end
    endtask

    task automatic test_credit_exhaustion_return;
        integer guard;
        begin
            $display("\n=== T4/T5 CREDIT EXHAUSTION + REAL CREDIT RETURN ===");
            reset_dut; clear_stress; stress_tx_count = 0;
            // R0 -> R1 -> EAST -> real four-entry sink. Eight flits are needed:
            // four occupy the sink, four fill R1 WEST, leaving R0 EAST at zero.
            for (int i=0; i<8; i++)
                inject_r0(make_stress_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h4000+i));
            wait_r0_east_zero;
            repeat (3) @(posedge clk);
            check(r0.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] == 0,
                  "T5 R0 EAST request credit is zero");
            check(r1.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] == 0,
                  "T5 R1 EAST request credit is zero");
            check(sink_full_vc0, "T5 downstream EAST VC0 FIFO is full");
            check(r1.full_west_vc0, "T5 R1 WEST VC0 FIFO is full");
            check(!r0_out_valid_east, "T5 R0 EAST is blocked at zero credit");

            // Read one real sink slot. noc_fifo emits credit_valid; R1 consumes
            // that credit, then dequeues one WEST flit, whose credit pulse returns
            // to R0. No manual credit pulse is fabricated.
            @(negedge clk); sink_rd_vc0 = 1'b1;
            @(posedge clk); #1; sink_rd_vc0 = 1'b0;

            guard = 0;
            while (!sink_credit_vc0 && guard < 20) begin
                @(posedge clk); #1; guard++;
            end
            check(guard < 20, "T5 real sink FIFO emits VC0 credit pulse");

            guard = 0;
            while (!r1_credit_out[PORT_WEST][VC_REQUEST] && guard < 50) begin
                @(posedge clk); #1; guard++;
            end
            check(guard < 50, "T5 R1 WEST dequeue emits real upstream credit");

            guard = 0;
            while ((r0.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] == 0) &&
                   guard < 50) begin
                @(posedge clk); guard++;
            end
            check(guard < 50, "T5 credit propagates back to R0 EAST");
            check(r0.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] > 0,
                  "T5 R0 EAST has credit again");
        end
    endtask

    task automatic test_response_vc_independence;
        integer guard;
        begin
            $display("\n=== T6 RESPONSE-VC INDEPENDENCE ===");
            reset_dut; clear_stress;
            for (int i=0; i<8; i++)
                inject_r0(make_stress_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h5000+i));
            wait_r0_east_zero;
            repeat (3) @(posedge clk);

            // Exhaust VC_REQUEST on R0 EAST, then inject an independent
            // VC_RESPONSE packet at R1 destined for R0.
            inject_r1(make_stress_flit(0,0,FLIT_HEAD_TAIL,VC_RESPONSE,16'h5A5A));

            guard = 0;
            while (!r1_out_valid_west && guard < 100) begin
                @(posedge clk); guard++;
            end
            check(guard < 100,
                  "T6 VC_RESPONSE crosses WEST while VC_REQUEST is exhausted");
            if (r1_out_valid_west) begin
                check(r1_out_west.vc_id == VC_RESPONSE,
                      "T6 VC_RESPONSE preserved across WEST");
                check(r1_out_west.flit_data[15:0] == 16'h5A5A,
                      "T6 response tag preserved across WEST");
            end

            guard = 0;
            while (!r0_out_valid_local && guard < 100) begin
                @(posedge clk); guard++;
            end
            check(guard < 100, "T6 response flit reaches R0 LOCAL");
            if (r0_out_valid_local) begin
                check(r0_out_local.vc_id == VC_RESPONSE,
                      "T6 VC_RESPONSE preserved at R0 LOCAL");
                check(r0_out_local.flit_data[15:0] == 16'h5A5A,
                      "T6 response tag preserved at R0 LOCAL");
            end
        end
    endtask

    task automatic test_bidirectional;
        integer guard;
        begin
            $display("\n=== T7 HEAD-ON BIDIRECTIONAL TRAFFIC ===");
            reset_dut; clear_stress;
            t7_east_seen = 1'b0;
            t7_west_seen = 1'b0;
            t7_monitor_enable = 1'b1;

            fork
                inject_r0(make_stress_flit(1,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h7001));
                inject_r1(make_stress_flit(0,0,FLIT_HEAD_TAIL,VC_RESPONSE,16'h7002));
            join

            guard = 0;
            while ((!t7_east_seen || !t7_west_seen) && guard < 100) begin
                @(posedge clk);
                guard++;
            end
            t7_monitor_enable = 1'b0;

            check(t7_east_seen, "T7 R0 to R1 LOCAL traffic progresses");
            check(t7_west_seen, "T7 R1 to R0 LOCAL traffic progresses");
        end
    endtask

    task automatic test_conservation;
        integer guard;
        begin
            $display("\n=== T8 FLIT CONSERVATION ===");
            reset_dut; clear_stress;
            t8_txc = 0;
            t8_rxc = 0;
            t8_monitor_enable = 1'b1;

            // Enable observation BEFORE injection. This avoids missing
            // one-cycle EAST transfers during the injection phase.
            for (int i=0; i<4; i++)
                inject_r0(make_stress_flit(1,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h8000+i));

            guard = 0;
            while ((t8_txc < 4 || t8_rxc < 4) && guard < 150) begin
                @(posedge clk);
                guard++;
            end
            t8_monitor_enable = 1'b0;

            check(t8_txc == 4, "T8 four flits transmitted on EAST");
            check(t8_rxc == 4, "T8 four flits delivered to R1 LOCAL");
            check(t8_txc == t8_rxc, "T8 legal-link TX equals RX");
        end
    endtask

    task automatic test_credit_invariants;
        begin
            $display("\n=== T9 CREDIT INVARIANTS ===");
            reset_dut; clear_stress;
            check(r0.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] <= FIFO_DEPTH,
                  "T9 R0 EAST request credit <= depth");
            check(r1.u_credit_control.credit_count[PORT_WEST][VC_REQUEST] <= FIFO_DEPTH,
                  "T9 R1 WEST request credit <= depth");
            check(r1.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] <= FIFO_DEPTH,
                  "T9 R1 EAST request credit <= depth");
            check(r0.u_credit_control.credit_count[PORT_WEST][VC_RESPONSE] <= FIFO_DEPTH,
                  "T9 R0 WEST response credit <= depth");
        end
    endtask

    task automatic test_reset_during_stress;
        begin
            $display("\n=== T10 RESET DURING STRESS ===");
            reset_dut; clear_stress;
            for (int i=0; i<6; i++)
                inject_r0(make_stress_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'hA000+i));
            repeat(5) @(posedge clk);
            rst=1'b1; repeat(3) @(posedge clk); rst=1'b0; repeat(2) @(posedge clk);
            check(r0.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] == FIFO_DEPTH,
                  "T10 reset restores R0 EAST credit");
            check(r1.u_credit_control.credit_count[PORT_EAST][VC_REQUEST] == FIFO_DEPTH,
                  "T10 reset restores R1 EAST credit");
            check(!r0_out_valid_east && !r1_out_valid_east,
                  "T10 reset clears stale EAST traffic");
        end
    endtask

    //==========================================================================
    // N-6 rebuild: conservation, RX hold tests
    //==========================================================================

    // Waits for the network to drain, then checks flit conservation.
    // in = out + resident, resident >= 0, so IN == OUT proves nothing is left
    // inside; a lost flit makes IN > OUT forever, a duplicate makes OUT > IN.
    task automatic check_conserved(input string tag);
        integer g, tin, tout;
        begin
            g = 0;
            while (g < 300 &&
                   !(((cn_r0_lin + cn_r1_lin) == (cn_r0_lout + cn_r1_lout + cn_r1_e)) &&
                     !r0_out_valid_local && !r1_out_valid_local &&
                     !r0_out_valid_east  && !r1_out_valid_west && !r1_out_valid_east)) begin
                @(posedge clk); #1; g++;
            end
            repeat (10) @(posedge clk); #1;   // no late or duplicate flits
            tin  = cn_r0_lin + cn_r1_lin;
            tout = cn_r0_lout + cn_r1_lout + cn_r1_e;
            $display("[INFO] %s counts: R0 lin=%0d ein=%0d lout=%0d eout=%0d | R1 lin=%0d win=%0d lout=%0d wout=%0d eout=%0d",
                     tag, cn_r0_lin, cn_r1_w, cn_r0_lout, cn_r0_e,
                     cn_r1_lin, cn_r0_e, cn_r1_lout, cn_r1_w, cn_r1_e);
            check(tin > 0, $sformatf("%s traffic observed (IN=%0d)", tag, tin));
            check(tin == tout,
                  $sformatf("%s TOTAL FLITS IN == TOTAL FLITS OUT (%0d == %0d)", tag, tin, tout));
            check((cn_r0_lin + cn_r1_w) == (cn_r0_lout + cn_r0_e),
                  $sformatf("%s R0 per-router IN == OUT", tag));
            check((cn_r1_lin + cn_r0_e) == (cn_r1_lout + cn_r1_w + cn_r1_e),
                  $sformatf("%s R1 per-router IN == OUT", tag));
            check(!r0_out_valid_local && !r1_out_valid_local &&
                  !r0_out_valid_east && !r1_out_valid_west && !r1_out_valid_east,
                  $sformatf("%s network drained (no output valid)", tag));
        end
    endtask

    // CPU0 -> CPU1 MEM_WR_REQ through the real NI0 (HEAD, BODY=addr, TAIL=data).
    task automatic cpu0_send_write(input logic [31:0] a, input logic [31:0] d);
        begin
            @(negedge clk);
            tx0_dest_coord = CPU1_COORD;
            tx0_msg_type   = MSG_MEM_WR_REQ;
            tx0_control    = '0;
            tx0_control[10:7] = 4'b1111;
            tx0_valid = 1'b1;
            while (!tx0_ready) @(negedge clk);
            @(posedge clk); #1; tx0_valid = 1'b0;

            @(negedge clk);
            tx0_payload_data = a; tx0_payload_valid = 1'b1;
            while (!tx0_payload_ready) @(negedge clk);
            @(posedge clk); #1; tx0_payload_valid = 1'b0;

            @(negedge clk);
            tx0_payload_data = d; tx0_payload_valid = 1'b1;
            while (!tx0_payload_ready) @(negedge clk);
            @(posedge clk); #1; tx0_payload_valid = 1'b0;

            wait (!tx0_busy);
        end
    endtask

    // T11: rx1_ready=0 BEFORE the packet arrives. Whole packet must sit in the
    // R1 eject buffer; nothing dequeued; head held stable; after release exactly
    // one complete, uncorrupted, in-order delivery.
    task automatic test_rx_hold_whole_packet;
        integer g, stall_bad;
        flit_t held;
        begin
            $display("\n=== T11 RX READY=0 HOLD - WHOLE PACKET, THEN RELEASE ===");
            reset_dut; clear_stress;
            @(negedge clk); rx1_ready = 1'b0;

            cpu0_send_write(CPU1_REMOTE_ADDR, 32'h1234_5678);

            g = 0;
            while (cn_r0_e < 3 && g < 100) begin @(posedge clk); #1; g++; end
            check(cn_r0_lin == 3, "T11 NI0 injected exactly 3 flits (HEAD, BODY, TAIL)");
            check(cn_r0_e == 3,   "T11 all 3 flits crossed R0 EAST -> R1 WEST");
            repeat (5) @(posedge clk); #1;

            check(r1_out_valid_local, "T11 R1 LOCAL out_valid high while tile ready=0");
            check(rx1_head_valid && !ni1_rx_ready,
                  "T11 NI1 presents head with noc_rx_ready=0");
            check(rx1_msg_type == MSG_MEM_WR_REQ && rx1_src_coord == CPU0_COORD,
                  "T11 held head is the CPU0 MEM_WR_REQ");

            held = r1_out_local;
            stall_bad = 0;
            for (int i = 0; i < 40; i++) begin
                @(posedge clk); #1;
                if (!r1_out_valid_local || (r1_out_local != held) ||
                    ni1_rx_ready || !rx1_head_valid)
                    stall_bad++;
            end
            check(stall_bad == 0, "T11 head flit held stable 40 cycles (valid=1, flit stable, ready=0)");
            check(cn_r1_lout == 0, "T11 no R1 LOCAL dequeue while ready=0");
            check(rx1_head_hs == 0 && rx1_pay_hs == 0, "T11 no NI1 delivery while ready=0");
            check(!rx1_busy, "T11 NI1 RX FSM did not advance while ready=0");

            @(negedge clk); rx1_ready = 1'b1;
            g = 0;
            while (rx1_pay_hs < 2 && g < 100) begin @(posedge clk); #1; g++; end
            repeat (20) @(posedge clk); #1;

            check(rx1_head_hs == 1, "T11 exactly one head delivered after release");
            check(rx1_pay_hs == 2,  "T11 exactly two payload flits delivered (no loss, no dup)");
            check(rx1_pay_log[0] == CPU1_REMOTE_ADDR, "T11 BODY = address (uncorrupted, in order)");
            check(rx1_pay_log[1] == 32'h1234_5678,    "T11 TAIL = data (uncorrupted, in order)");
            check(rx1_perr == 0, "T11 no NI1 protocol error");
            check_conserved("T11");
        end
    endtask

    // T12: rx1_ready drops right AFTER the HEAD handshake (mid-packet).
    task automatic test_rx_hold_mid_packet;
        integer g, stall_bad;
        flit_t held;
        begin
            $display("\n=== T12 RX READY=0 HOLD - MID-PACKET (after HEAD), THEN RELEASE ===");
            reset_dut; clear_stress;

            fork
                cpu0_send_write(CPU1_REMOTE_ADDR, 32'h8765_4321);
                begin
                    g = 0;
                    while (rx1_head_hs == 0 && g < 200) begin @(posedge clk); #1; g++; end
                    rx1_ready = 1'b0;      // posedge+1: HEAD taken, BODY not yet
                end
            join
            check(rx1_head_hs == 1, "T12 head accepted before ready dropped");

            g = 0;
            while (cn_r0_e < 3 && g < 100) begin @(posedge clk); #1; g++; end
            repeat (5) @(posedge clk); #1;

            check(rx1_busy, "T12 NI1 is mid-packet (RX_PAYLOAD)");
            check(r1_out_valid_local && !ni1_rx_ready,
                  "T12 BODY waiting at R1 LOCAL with noc_rx_ready=0");
            check(rx1_payload_valid && (rx1_payload_data == CPU1_REMOTE_ADDR),
                  "T12 NI1 presents BODY = address");

            held = r1_out_local;
            stall_bad = 0;
            for (int i = 0; i < 40; i++) begin
                @(posedge clk); #1;
                if (!r1_out_valid_local || (r1_out_local != held) || ni1_rx_ready ||
                    !rx1_payload_valid || (rx1_payload_data != CPU1_REMOTE_ADDR))
                    stall_bad++;
            end
            check(stall_bad == 0, "T12 BODY held stable 40 cycles mid-packet");
            check(cn_r1_lout == 1, "T12 only HEAD dequeued from R1 LOCAL while ready=0");
            check(rx1_pay_hs == 0, "T12 no payload delivered while ready=0");

            @(negedge clk); rx1_ready = 1'b1;
            g = 0;
            while (rx1_pay_hs < 2 && g < 100) begin @(posedge clk); #1; g++; end
            repeat (20) @(posedge clk); #1;

            check(rx1_head_hs == 1, "T12 still exactly one head (no duplicate)");
            check(rx1_pay_hs == 2,  "T12 exactly two payload flits delivered (no loss, no dup)");
            check(rx1_pay_log[0] == CPU1_REMOTE_ADDR, "T12 BODY = address (uncorrupted, in order)");
            check(rx1_pay_log[1] == 32'h8765_4321,    "T12 TAIL = data (uncorrupted, in order)");
            check(rx1_perr == 0, "T12 no NI1 protocol error");
            check_conserved("T12");
        end
    endtask

    // T13: LOCAL input backpressure at FULL (kills M-c: in_ready_local tied 1).
    // 12 VC_REQUEST flits fill sink(4) + R1 WEST(4) + R0 LOCAL VC0(4). A 13th
    // is then held valid: in_ready_local must stay 0 and nothing may be taken.
    // Draining the real sink must eventually admit it, and exactly 13 flits
    // must arrive at the sink, in order, with no loss or duplicate.
    task automatic test_local_input_full_backpressure;
        integer g, ready_seen, got;
        logic [15:0] tags [0:15];
        logic ok_order;
        begin
            $display("\n=== T13 LOCAL INPUT BACKPRESSURE AT FULL (in_ready_local) ===");
            reset_dut; clear_stress;
            for (int i = 0; i < 12; i++)
                inject_r0(make_stress_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'hD000 + 16'(i)));
            repeat (10) @(posedge clk); #1;
            check(cn_r0_lin == 12, "T13 12 flits accepted into R0 LOCAL");
            check(r0.full_local_vc0, "T13 R0 LOCAL VC0 FIFO full (observation)");

            // Present the 13th and hold it (valid/ready rule: no withdrawal).
            @(negedge clk);
            stress_r0_local_flit  = make_stress_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'hD00C);
            stress_r0_local_valid = 1'b1;
            ready_seen = 0;
            for (int i = 0; i < 20; i++) begin
                #1; if (r0_in_ready_local) ready_seen++;
                @(negedge clk);
            end
            check(ready_seen == 0, "T13 in_ready_local=0 for 20 cycles while LOCAL VC0 full");
            check(cn_r0_lin == 12, "T13 13th flit NOT taken while full");

            // Drain the real sink; the 13th must be admitted and delivered.
            got = 0;
            fork
                begin : hold13
                    #1;
                    while (!r0_in_ready_local) begin @(negedge clk); #1; end
                    @(posedge clk); #1;
                    stress_r0_local_valid = 1'b0;
                    stress_r0_local_flit  = '0;
                end
                begin : drain
                    g = 0;
                    while (got < 13 && g < 600) begin
                        @(negedge clk);
                        if (!sink_empty_vc0) begin
                            if (got < 16) tags[got] = sink_flit_vc0.flit_data[15:0];
                            got++;
                            sink_rd_vc0 = 1'b1;
                            @(posedge clk); #1;
                            sink_rd_vc0 = 1'b0;
                        end
                        g++;
                    end
                end
            join
            repeat (20) @(posedge clk); #1;
            check(cn_r0_lin == 13, "T13 13th flit admitted after drain");
            check(got == 13, $sformatf("T13 exactly 13 flits reached the sink (got %0d)", got));
            ok_order = 1'b1;
            for (int i = 0; i < 13; i++)
                if (i < got && tags[i] != (16'hD000 + 16'(i))) ok_order = 1'b0;
            check(ok_order, "T13 sink order D000..D00C (no loss, dup, reorder, corruption)");
            check(sink_empty_vc0 && (cn_r1_e == 13), "T13 no extra flit after the 13th");
        end
    endtask

    // Main
    //--------------------------------------------------------------------------

    initial begin
        checks = 0; errors = 0; cycle_count = 0; stress_tx_count = 0;
        t7_monitor_enable = 1'b0;
        t7_east_seen = 1'b0;
        t7_west_seen = 1'b0;
        t8_monitor_enable = 1'b0;
        t8_txc = 0;
        t8_rxc = 0;
        mux_collisions = 0;
        rx0_ready = 1'b1;
        rx1_ready = 1'b1;
        clear_stress;

        // Existing current-source end-to-end integration.
        test_decoder_contract;
        test_write;
        check_conserved("T1");
        test_read;
        check_conserved("T2");

        // N-6 stress.
        test_credit_exhaustion_return;
        test_response_vc_independence;
        test_bidirectional;
        check_conserved("T7");
        test_conservation;
        check_conserved("T8");
        test_credit_invariants;
        test_reset_during_stress;

        // N-6 rebuild: tile-side RX backpressure through NI -> router eject.
        test_rx_hold_whole_packet;
        test_rx_hold_mid_packet;
        test_local_input_full_backpressure;

        check(mux_collisions == 0, "stress injector never collided with NI on LOCAL");

        $display("\n====================================================");
        $display("N-6 TWO-TILE STRESS RESULT");
        $display("Checks = %0d", checks);
        $display("Errors = %0d", errors);
        if (errors == 0) $display("RESULT = PASS");
        else             $display("RESULT = FAIL");
        $display("====================================================");
        #100;
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $display("[FATAL] N-6 STRESS TIMEOUT");
        $display("RESULT = FAIL");
        $finish;
    end

endmodule

