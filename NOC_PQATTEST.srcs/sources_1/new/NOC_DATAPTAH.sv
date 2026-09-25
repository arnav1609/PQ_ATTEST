//=============================================================================
// Module 4: NoC Router Datapath
// File: noc_router_datapath.sv
//
// Purpose:
//     Organise the 15 input/VC FIFOs of a NoC router and present one flit
//     per physical input to the crossbar.
//
// Architecture:
//     5 physical input ports x 3 virtual channels = 15 FIFOs
//
//     Ports:            NORTH, SOUTH, EAST, WEST, LOCAL
//     Virtual channels: VC_REQUEST, VC_RESPONSE, VC_ATTESTATION
//
// Responsibilities:
//     - Instantiate one FIFO per input-port / VC combination
//     - Decode the incoming flit's VC ID and steer the write
//     - Expose FIFO head flits and status
//     - Expose free-slot counts and credit pulses
//     - Select one VC from each physical input for the crossbar
//
// Does NOT handle:
//     - XY routing
//     - Arbitration or output allocation
//     - Credit accounting
//     - Attestation checking
//
// REVISION: Review 01 repairs applied
//   D3 / L-06  VC-selection muxes changed from unique case to priority case.
//              unique case on MODULE INPUTS licenses synthesis to optimise
//              assuming one-hot. The allocator that is supposed to guarantee
//              one-hot does not exist yet, so that licence was being granted
//              against an unproven assumption. priority case is well defined
//              for every input combination, and an assertion now checks the
//              one-hot property explicitly instead of assuming it.
//   D5 / L-05  crossbar_valid_* is now the single source of truth, because
//              flit_t no longer carries a valid bit.
//   D6         DEPTH passed explicitly to every FIFO, from per-VC parameters.
//   D7         occupancy outputs left explicitly unconnected rather than
//              wired to 15 dead signals.
//   F5         Credit pulses brought out for noc_credit_control.
//   L-02       File renamed from NOC_ROUTER_DATAPATH.sv.
//
//   The 15 FIFOs remain EXPLICITLY instantiated rather than generated. The
//   flat structure was a deliberate choice for ILA visibility and waveform
//   readability, and it has produced zero wiring errors so far. Converting
//   to generate loops immediately before a synthesis probe would add risk
//   without improving the probe, and the probe may change the VC count
//   anyway. Revisit after the probe, not before.
//
//=============================================================================
// OUTSTANDING DEBTS -- READ BEFORE BUILDING THE ALLOCATOR
//
//   D1  NO BACKPRESSURE EXISTS YET.
//       full_* and free_* are exposed and nothing consumes them. There is
//       no credit protocol. Until noc_credit_control is built, a full VC
//       buffer DISCARDS the incoming flit. The assertion inside noc_fifo
//       makes this loud, but it does not prevent it. Do not interpret a
//       clean simulation at low load as working flow control.
//
//   D2  NO ROUTE PERSISTENCE EXISTS YET.
//       XY routing computes a direction from a HEAD flit's coordinates.
//       Body and tail flits carry no coordinates. A route table of 15
//       entries per router -- output port plus a packet-active bit, one per
//       input VC -- is REQUIRED before body flits can be routed at all.
//       That is noc_route_table, and it must be built before the allocator.
//
//   L-07  WORMHOLE OUTPUT RESERVATION IS A HARD ALLOCATOR CONTRACT.
//       Once a head flit is granted an output port, that output and that
//       VC must remain reserved for the same packet until its tail flit has
//       been forwarded. With MAC_ENABLE set, the tail is the last MAC flit,
//       not the last payload flit. If sel_* or the crossbar select changes
//       mid-packet, two packets interleave on one link and both are
//       destroyed. Nothing in this module can detect that.
//=============================================================================

`timescale 1ns/1ps
module noc_router_datapath (

    input  logic clk,
    input  logic rst,

    //=========================================================================
    // PHYSICAL INPUTS
    //=========================================================================

    input  noc_pkg::flit_t in_flit_north,
    input  logic           in_valid_north,

    input  noc_pkg::flit_t in_flit_south,
    input  logic           in_valid_south,

    input  noc_pkg::flit_t in_flit_east,
    input  logic           in_valid_east,

    input  noc_pkg::flit_t in_flit_west,
    input  logic           in_valid_west,

    input  noc_pkg::flit_t in_flit_local,
    input  logic           in_valid_local,

    //=========================================================================
    // FIFO READ ENABLES
    //
    // Driven by the allocator. Asserting a read enable on an empty FIFO is
    // a protocol violation and is checked inside noc_fifo.
    //=========================================================================

    input  logic rd_en_north_vc0,
    input  logic rd_en_north_vc1,
    input  logic rd_en_north_vc2,

    input  logic rd_en_south_vc0,
    input  logic rd_en_south_vc1,
    input  logic rd_en_south_vc2,

    input  logic rd_en_east_vc0,
    input  logic rd_en_east_vc1,
    input  logic rd_en_east_vc2,

    input  logic rd_en_west_vc0,
    input  logic rd_en_west_vc1,
    input  logic rd_en_west_vc2,

    input  logic rd_en_local_vc0,
    input  logic rd_en_local_vc1,
    input  logic rd_en_local_vc2,

    //=========================================================================
    // VC SELECTION FOR EACH PHYSICAL INPUT
    //
    // At most one bit per physical input may be asserted. This is CHECKED,
    // not assumed -- see the assertions at the bottom of this file.
    //=========================================================================

    input  logic sel_north_vc0,
    input  logic sel_north_vc1,
    input  logic sel_north_vc2,

    input  logic sel_south_vc0,
    input  logic sel_south_vc1,
    input  logic sel_south_vc2,

    input  logic sel_east_vc0,
    input  logic sel_east_vc1,
    input  logic sel_east_vc2,

    input  logic sel_west_vc0,
    input  logic sel_west_vc1,
    input  logic sel_west_vc2,

    input  logic sel_local_vc0,
    input  logic sel_local_vc1,
    input  logic sel_local_vc2,

    //=========================================================================
    // FIFO HEAD FLITS
    //=========================================================================

    output noc_pkg::flit_t head_north_vc0,
    output noc_pkg::flit_t head_north_vc1,
    output noc_pkg::flit_t head_north_vc2,

    output noc_pkg::flit_t head_south_vc0,
    output noc_pkg::flit_t head_south_vc1,
    output noc_pkg::flit_t head_south_vc2,

    output noc_pkg::flit_t head_east_vc0,
    output noc_pkg::flit_t head_east_vc1,
    output noc_pkg::flit_t head_east_vc2,

    output noc_pkg::flit_t head_west_vc0,
    output noc_pkg::flit_t head_west_vc1,
    output noc_pkg::flit_t head_west_vc2,

    output noc_pkg::flit_t head_local_vc0,
    output noc_pkg::flit_t head_local_vc1,
    output noc_pkg::flit_t head_local_vc2,

    //=========================================================================
    // FIFO EMPTY STATUS
    //=========================================================================

    output logic empty_north_vc0,
    output logic empty_north_vc1,
    output logic empty_north_vc2,

    output logic empty_south_vc0,
    output logic empty_south_vc1,
    output logic empty_south_vc2,

    output logic empty_east_vc0,
    output logic empty_east_vc1,
    output logic empty_east_vc2,

    output logic empty_west_vc0,
    output logic empty_west_vc1,
    output logic empty_west_vc2,

    output logic empty_local_vc0,
    output logic empty_local_vc1,
    output logic empty_local_vc2,

    //=========================================================================
    // FIFO FULL STATUS
    //=========================================================================

    output logic full_north_vc0,
    output logic full_north_vc1,
    output logic full_north_vc2,

    output logic full_south_vc0,
    output logic full_south_vc1,
    output logic full_south_vc2,

    output logic full_east_vc0,
    output logic full_east_vc1,
    output logic full_east_vc2,

    output logic full_west_vc0,
    output logic full_west_vc1,
    output logic full_west_vc2,

    output logic full_local_vc0,
    output logic full_local_vc1,
    output logic full_local_vc2,

    //=========================================================================
    // FIFO FREE-SLOT COUNTS
    //
    // Widths are per-VC because the VC depths are independent. VC2 carries
    // the attestation response, which is far longer than any memory packet.
    //=========================================================================

    output logic [noc_pkg::VC0_CNT_WIDTH-1:0] free_north_vc0,
    output logic [noc_pkg::VC1_CNT_WIDTH-1:0] free_north_vc1,
    output logic [noc_pkg::VC2_CNT_WIDTH-1:0] free_north_vc2,

    output logic [noc_pkg::VC0_CNT_WIDTH-1:0] free_south_vc0,
    output logic [noc_pkg::VC1_CNT_WIDTH-1:0] free_south_vc1,
    output logic [noc_pkg::VC2_CNT_WIDTH-1:0] free_south_vc2,

    output logic [noc_pkg::VC0_CNT_WIDTH-1:0] free_east_vc0,
    output logic [noc_pkg::VC1_CNT_WIDTH-1:0] free_east_vc1,
    output logic [noc_pkg::VC2_CNT_WIDTH-1:0] free_east_vc2,

    output logic [noc_pkg::VC0_CNT_WIDTH-1:0] free_west_vc0,
    output logic [noc_pkg::VC1_CNT_WIDTH-1:0] free_west_vc1,
    output logic [noc_pkg::VC2_CNT_WIDTH-1:0] free_west_vc2,

    output logic [noc_pkg::VC0_CNT_WIDTH-1:0] free_local_vc0,
    output logic [noc_pkg::VC1_CNT_WIDTH-1:0] free_local_vc1,
    output logic [noc_pkg::VC2_CNT_WIDTH-1:0] free_local_vc2,

    //=========================================================================
    // CREDIT PULSES
    //
    // One cycle high, one clock after a slot is freed. Consumed by
    // noc_credit_control, which returns the credit to the upstream router.
    //=========================================================================

    output logic credit_north_vc0,
    output logic credit_north_vc1,
    output logic credit_north_vc2,

    output logic credit_south_vc0,
    output logic credit_south_vc1,
    output logic credit_south_vc2,

    output logic credit_east_vc0,
    output logic credit_east_vc1,
    output logic credit_east_vc2,

    output logic credit_west_vc0,
    output logic credit_west_vc1,
    output logic credit_west_vc2,

    output logic credit_local_vc0,
    output logic credit_local_vc1,
    output logic credit_local_vc2,

    //=========================================================================
    // CROSSBAR INPUTS
    //=========================================================================

    output noc_pkg::flit_t crossbar_in_north,
    output noc_pkg::flit_t crossbar_in_south,
    output noc_pkg::flit_t crossbar_in_east,
    output noc_pkg::flit_t crossbar_in_west,
    output noc_pkg::flit_t crossbar_in_local,

    output logic crossbar_valid_north,
    output logic crossbar_valid_south,
    output logic crossbar_valid_east,
    output logic crossbar_valid_west,
    output logic crossbar_valid_local

);

    import noc_pkg::*;

    //=========================================================================
    // FIFO WRITE ENABLES
    //=========================================================================

    logic wr_north_vc0, wr_north_vc1, wr_north_vc2;
    logic wr_south_vc0, wr_south_vc1, wr_south_vc2;
    logic wr_east_vc0,  wr_east_vc1,  wr_east_vc2;
    logic wr_west_vc0,  wr_west_vc1,  wr_west_vc2;
    logic wr_local_vc0, wr_local_vc1, wr_local_vc2;


    //=========================================================================
    // VC DECODER
    //
    // Each incoming flit is steered to exactly one VC FIFO by its vc_id.
    //
    // unique case is SAFE here, unlike in the VC muxes below, because vc_id
    // is a single encoded field rather than a set of independent bits, so
    // the branches cannot overlap by construction. The default covers the
    // unused fourth encoding.
    //=========================================================================

    always_comb begin

        wr_north_vc0 = 1'b0;  wr_north_vc1 = 1'b0;  wr_north_vc2 = 1'b0;
        wr_south_vc0 = 1'b0;  wr_south_vc1 = 1'b0;  wr_south_vc2 = 1'b0;
        wr_east_vc0  = 1'b0;  wr_east_vc1  = 1'b0;  wr_east_vc2  = 1'b0;
        wr_west_vc0  = 1'b0;  wr_west_vc1  = 1'b0;  wr_west_vc2  = 1'b0;
        wr_local_vc0 = 1'b0;  wr_local_vc1 = 1'b0;  wr_local_vc2 = 1'b0;

        //---------------------------------------------------------------------
        // NORTH
        //---------------------------------------------------------------------

        if (in_valid_north) begin
            unique case (vc_e'(in_flit_north.vc_id))
                VC_REQUEST:     wr_north_vc0 = 1'b1;
                VC_RESPONSE:    wr_north_vc1 = 1'b1;
                VC_ATTESTATION: wr_north_vc2 = 1'b1;
                default: begin
                    wr_north_vc0 = 1'b0;
                    wr_north_vc1 = 1'b0;
                    wr_north_vc2 = 1'b0;
                end
            endcase
        end

        //---------------------------------------------------------------------
        // SOUTH
        //---------------------------------------------------------------------

        if (in_valid_south) begin
            unique case (vc_e'(in_flit_south.vc_id))
                VC_REQUEST:     wr_south_vc0 = 1'b1;
                VC_RESPONSE:    wr_south_vc1 = 1'b1;
                VC_ATTESTATION: wr_south_vc2 = 1'b1;
                default: begin
                    wr_south_vc0 = 1'b0;
                    wr_south_vc1 = 1'b0;
                    wr_south_vc2 = 1'b0;
                end
            endcase
        end

        //---------------------------------------------------------------------
        // EAST
        //---------------------------------------------------------------------

        if (in_valid_east) begin
            unique case (vc_e'(in_flit_east.vc_id))
                VC_REQUEST:     wr_east_vc0 = 1'b1;
                VC_RESPONSE:    wr_east_vc1 = 1'b1;
                VC_ATTESTATION: wr_east_vc2 = 1'b1;
                default: begin
                    wr_east_vc0 = 1'b0;
                    wr_east_vc1 = 1'b0;
                    wr_east_vc2 = 1'b0;
                end
            endcase
        end

        //---------------------------------------------------------------------
        // WEST
        //---------------------------------------------------------------------

        if (in_valid_west) begin
            unique case (vc_e'(in_flit_west.vc_id))
                VC_REQUEST:     wr_west_vc0 = 1'b1;
                VC_RESPONSE:    wr_west_vc1 = 1'b1;
                VC_ATTESTATION: wr_west_vc2 = 1'b1;
                default: begin
                    wr_west_vc0 = 1'b0;
                    wr_west_vc1 = 1'b0;
                    wr_west_vc2 = 1'b0;
                end
            endcase
        end

        //---------------------------------------------------------------------
        // LOCAL
        //---------------------------------------------------------------------

        if (in_valid_local) begin
            unique case (vc_e'(in_flit_local.vc_id))
                VC_REQUEST:     wr_local_vc0 = 1'b1;
                VC_RESPONSE:    wr_local_vc1 = 1'b1;
                VC_ATTESTATION: wr_local_vc2 = 1'b1;
                default: begin
                    wr_local_vc0 = 1'b0;
                    wr_local_vc1 = 1'b0;
                    wr_local_vc2 = 1'b0;
                end
            endcase
        end

    end


    //=========================================================================
    // NORTH FIFOs
    //=========================================================================

    noc_fifo #(.DEPTH (VC0_DEPTH)) north_vc0_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_north),
        .wr_en        (wr_north_vc0),
        .rd_en        (rd_en_north_vc0),
        .rd_flit      (head_north_vc0),
        .empty        (empty_north_vc0),
        .full         (full_north_vc0),
        .occupancy    (),
        .free_slots   (free_north_vc0),
        .credit_valid (credit_north_vc0)
    );

    noc_fifo #(.DEPTH (VC1_DEPTH)) north_vc1_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_north),
        .wr_en        (wr_north_vc1),
        .rd_en        (rd_en_north_vc1),
        .rd_flit      (head_north_vc1),
        .empty        (empty_north_vc1),
        .full         (full_north_vc1),
        .occupancy    (),
        .free_slots   (free_north_vc1),
        .credit_valid (credit_north_vc1)
    );

    noc_fifo #(.DEPTH (VC2_DEPTH)) north_vc2_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_north),
        .wr_en        (wr_north_vc2),
        .rd_en        (rd_en_north_vc2),
        .rd_flit      (head_north_vc2),
        .empty        (empty_north_vc2),
        .full         (full_north_vc2),
        .occupancy    (),
        .free_slots   (free_north_vc2),
        .credit_valid (credit_north_vc2)
    );


    //=========================================================================
    // SOUTH FIFOs
    //=========================================================================

    noc_fifo #(.DEPTH (VC0_DEPTH)) south_vc0_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_south),
        .wr_en        (wr_south_vc0),
        .rd_en        (rd_en_south_vc0),
        .rd_flit      (head_south_vc0),
        .empty        (empty_south_vc0),
        .full         (full_south_vc0),
        .occupancy    (),
        .free_slots   (free_south_vc0),
        .credit_valid (credit_south_vc0)
    );

    noc_fifo #(.DEPTH (VC1_DEPTH)) south_vc1_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_south),
        .wr_en        (wr_south_vc1),
        .rd_en        (rd_en_south_vc1),
        .rd_flit      (head_south_vc1),
        .empty        (empty_south_vc1),
        .full         (full_south_vc1),
        .occupancy    (),
        .free_slots   (free_south_vc1),
        .credit_valid (credit_south_vc1)
    );

    noc_fifo #(.DEPTH (VC2_DEPTH)) south_vc2_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_south),
        .wr_en        (wr_south_vc2),
        .rd_en        (rd_en_south_vc2),
        .rd_flit      (head_south_vc2),
        .empty        (empty_south_vc2),
        .full         (full_south_vc2),
        .occupancy    (),
        .free_slots   (free_south_vc2),
        .credit_valid (credit_south_vc2)
    );


    //=========================================================================
    // EAST FIFOs
    //=========================================================================

    noc_fifo #(.DEPTH (VC0_DEPTH)) east_vc0_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_east),
        .wr_en        (wr_east_vc0),
        .rd_en        (rd_en_east_vc0),
        .rd_flit      (head_east_vc0),
        .empty        (empty_east_vc0),
        .full         (full_east_vc0),
        .occupancy    (),
        .free_slots   (free_east_vc0),
        .credit_valid (credit_east_vc0)
    );

    noc_fifo #(.DEPTH (VC1_DEPTH)) east_vc1_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_east),
        .wr_en        (wr_east_vc1),
        .rd_en        (rd_en_east_vc1),
        .rd_flit      (head_east_vc1),
        .empty        (empty_east_vc1),
        .full         (full_east_vc1),
        .occupancy    (),
        .free_slots   (free_east_vc1),
        .credit_valid (credit_east_vc1)
    );

    noc_fifo #(.DEPTH (VC2_DEPTH)) east_vc2_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_east),
        .wr_en        (wr_east_vc2),
        .rd_en        (rd_en_east_vc2),
        .rd_flit      (head_east_vc2),
        .empty        (empty_east_vc2),
        .full         (full_east_vc2),
        .occupancy    (),
        .free_slots   (free_east_vc2),
        .credit_valid (credit_east_vc2)
    );


    //=========================================================================
    // WEST FIFOs
    //=========================================================================

    noc_fifo #(.DEPTH (VC0_DEPTH)) west_vc0_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_west),
        .wr_en        (wr_west_vc0),
        .rd_en        (rd_en_west_vc0),
        .rd_flit      (head_west_vc0),
        .empty        (empty_west_vc0),
        .full         (full_west_vc0),
        .occupancy    (),
        .free_slots   (free_west_vc0),
        .credit_valid (credit_west_vc0)
    );

    noc_fifo #(.DEPTH (VC1_DEPTH)) west_vc1_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_west),
        .wr_en        (wr_west_vc1),
        .rd_en        (rd_en_west_vc1),
        .rd_flit      (head_west_vc1),
        .empty        (empty_west_vc1),
        .full         (full_west_vc1),
        .occupancy    (),
        .free_slots   (free_west_vc1),
        .credit_valid (credit_west_vc1)
    );

    noc_fifo #(.DEPTH (VC2_DEPTH)) west_vc2_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_west),
        .wr_en        (wr_west_vc2),
        .rd_en        (rd_en_west_vc2),
        .rd_flit      (head_west_vc2),
        .empty        (empty_west_vc2),
        .full         (full_west_vc2),
        .occupancy    (),
        .free_slots   (free_west_vc2),
        .credit_valid (credit_west_vc2)
    );


    //=========================================================================
    // LOCAL FIFOs
    //=========================================================================

    noc_fifo #(.DEPTH (VC0_DEPTH)) local_vc0_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_local),
        .wr_en        (wr_local_vc0),
        .rd_en        (rd_en_local_vc0),
        .rd_flit      (head_local_vc0),
        .empty        (empty_local_vc0),
        .full         (full_local_vc0),
        .occupancy    (),
        .free_slots   (free_local_vc0),
        .credit_valid (credit_local_vc0)
    );

    noc_fifo #(.DEPTH (VC1_DEPTH)) local_vc1_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_local),
        .wr_en        (wr_local_vc1),
        .rd_en        (rd_en_local_vc1),
        .rd_flit      (head_local_vc1),
        .empty        (empty_local_vc1),
        .full         (full_local_vc1),
        .occupancy    (),
        .free_slots   (free_local_vc1),
        .credit_valid (credit_local_vc1)
    );

    noc_fifo #(.DEPTH (VC2_DEPTH)) local_vc2_fifo (
        .clk          (clk),
        .rst          (rst),
        .wr_flit      (in_flit_local),
        .wr_en        (wr_local_vc2),
        .rd_en        (rd_en_local_vc2),
        .rd_flit      (head_local_vc2),
        .empty        (empty_local_vc2),
        .full         (full_local_vc2),
        .occupancy    (),
        .free_slots   (free_local_vc2),
        .credit_valid (credit_local_vc2)
    );


    //=========================================================================
    // VC-TO-PHYSICAL-INPUT MUXING
    //
    // Each physical input has three VC FIFO heads. The allocator selects at
    // most one for presentation to the 5x5 crossbar.
    //
    // priority case, NOT unique case.  (D3 / L-06)
    //
    //   unique case tells synthesis it may assume the select bits are
    //   one-hot and optimise on that basis. These are module INPUTS driven
    //   by an allocator that has not been written. If it ever asserts two
    //   bits, hardware does something undefined and simulation does not
    //   reproduce it.
    //
    //   priority case is fully defined for all eight combinations: lowest
    //   VC index wins, zero-hot falls to the default. The one-hot property
    //   is then CHECKED by assertion rather than assumed by the compiler.
    //=========================================================================

    always_comb begin

        crossbar_in_north    = '0;
        crossbar_valid_north = 1'b0;

        crossbar_in_south    = '0;
        crossbar_valid_south = 1'b0;

        crossbar_in_east     = '0;
        crossbar_valid_east  = 1'b0;

        crossbar_in_west     = '0;
        crossbar_valid_west  = 1'b0;

        crossbar_in_local    = '0;
        crossbar_valid_local = 1'b0;


        //---------------------------------------------------------------------
        // NORTH VC MUX
        //---------------------------------------------------------------------

        priority case (1'b1)

            sel_north_vc0: begin
                crossbar_in_north    = head_north_vc0;
                crossbar_valid_north = !empty_north_vc0;
            end

            sel_north_vc1: begin
                crossbar_in_north    = head_north_vc1;
                crossbar_valid_north = !empty_north_vc1;
            end

            sel_north_vc2: begin
                crossbar_in_north    = head_north_vc2;
                crossbar_valid_north = !empty_north_vc2;
            end

            default: begin
                crossbar_in_north    = '0;
                crossbar_valid_north = 1'b0;
            end

        endcase


        //---------------------------------------------------------------------
        // SOUTH VC MUX
        //---------------------------------------------------------------------

        priority case (1'b1)

            sel_south_vc0: begin
                crossbar_in_south    = head_south_vc0;
                crossbar_valid_south = !empty_south_vc0;
            end

            sel_south_vc1: begin
                crossbar_in_south    = head_south_vc1;
                crossbar_valid_south = !empty_south_vc1;
            end

            sel_south_vc2: begin
                crossbar_in_south    = head_south_vc2;
                crossbar_valid_south = !empty_south_vc2;
            end

            default: begin
                crossbar_in_south    = '0;
                crossbar_valid_south = 1'b0;
            end

        endcase


        //---------------------------------------------------------------------
        // EAST VC MUX
        //---------------------------------------------------------------------

        priority case (1'b1)

            sel_east_vc0: begin
                crossbar_in_east    = head_east_vc0;
                crossbar_valid_east = !empty_east_vc0;
            end

            sel_east_vc1: begin
                crossbar_in_east    = head_east_vc1;
                crossbar_valid_east = !empty_east_vc1;
            end

            sel_east_vc2: begin
                crossbar_in_east    = head_east_vc2;
                crossbar_valid_east = !empty_east_vc2;
            end

            default: begin
                crossbar_in_east    = '0;
                crossbar_valid_east = 1'b0;
            end

        endcase


        //---------------------------------------------------------------------
        // WEST VC MUX
        //---------------------------------------------------------------------

        priority case (1'b1)

            sel_west_vc0: begin
                crossbar_in_west    = head_west_vc0;
                crossbar_valid_west = !empty_west_vc0;
            end

            sel_west_vc1: begin
                crossbar_in_west    = head_west_vc1;
                crossbar_valid_west = !empty_west_vc1;
            end

            sel_west_vc2: begin
                crossbar_in_west    = head_west_vc2;
                crossbar_valid_west = !empty_west_vc2;
            end

            default: begin
                crossbar_in_west    = '0;
                crossbar_valid_west = 1'b0;
            end

        endcase


        //---------------------------------------------------------------------
        // LOCAL VC MUX
        //---------------------------------------------------------------------

        priority case (1'b1)

            sel_local_vc0: begin
                crossbar_in_local    = head_local_vc0;
                crossbar_valid_local = !empty_local_vc0;
            end

            sel_local_vc1: begin
                crossbar_in_local    = head_local_vc1;
                crossbar_valid_local = !empty_local_vc1;
            end

            sel_local_vc2: begin
                crossbar_in_local    = head_local_vc2;
                crossbar_valid_local = !empty_local_vc2;
            end

            default: begin
                crossbar_in_local    = '0;
                crossbar_valid_local = 1'b0;
            end

        endcase

    end


    //=========================================================================
    // ASSERTIONS
    //
    // The one-hot property that unique case used to ASSUME is now CHECKED.
    // $onehot0 accepts zero-hot, which is legal: an input with no VC
    // selected simply presents nothing to the crossbar this cycle.
    //=========================================================================

    property p_onehot0_north;
        @(posedge clk) disable iff (rst)
        $onehot0({sel_north_vc0, sel_north_vc1, sel_north_vc2});
    endproperty

    a_onehot0_north: assert property (p_onehot0_north)
        else $error("noc_router_datapath: multiple VCs selected on NORTH input");


    property p_onehot0_south;
        @(posedge clk) disable iff (rst)
        $onehot0({sel_south_vc0, sel_south_vc1, sel_south_vc2});
    endproperty

    a_onehot0_south: assert property (p_onehot0_south)
        else $error("noc_router_datapath: multiple VCs selected on SOUTH input");


    property p_onehot0_east;
        @(posedge clk) disable iff (rst)
        $onehot0({sel_east_vc0, sel_east_vc1, sel_east_vc2});
    endproperty

    a_onehot0_east: assert property (p_onehot0_east)
        else $error("noc_router_datapath: multiple VCs selected on EAST input");


    property p_onehot0_west;
        @(posedge clk) disable iff (rst)
        $onehot0({sel_west_vc0, sel_west_vc1, sel_west_vc2});
    endproperty

    a_onehot0_west: assert property (p_onehot0_west)
        else $error("noc_router_datapath: multiple VCs selected on WEST input");


    property p_onehot0_local;
        @(posedge clk) disable iff (rst)
        $onehot0({sel_local_vc0, sel_local_vc1, sel_local_vc2});
    endproperty

    a_onehot0_local: assert property (p_onehot0_local)
        else $error("noc_router_datapath: multiple VCs selected on LOCAL input");


    //-------------------------------------------------------------------------
    // A flit must never arrive on an unused VC encoding. vc_id is 2 bits but
    // only three values are legal, and the fourth would be silently
    // discarded by the VC decoder above.
    //-------------------------------------------------------------------------

    property p_legal_vc_north;
        @(posedge clk) disable iff (rst)
        in_valid_north |-> (in_flit_north.vc_id < VC_ID_WIDTH'(NUM_VC));
    endproperty

    a_legal_vc_north: assert property (p_legal_vc_north)
        else $error("noc_router_datapath: flit arrived on NORTH with an illegal vc_id");


    property p_legal_vc_south;
        @(posedge clk) disable iff (rst)
        in_valid_south |-> (in_flit_south.vc_id < VC_ID_WIDTH'(NUM_VC));
    endproperty

    a_legal_vc_south: assert property (p_legal_vc_south)
        else $error("noc_router_datapath: flit arrived on SOUTH with an illegal vc_id");


    property p_legal_vc_east;
        @(posedge clk) disable iff (rst)
        in_valid_east |-> (in_flit_east.vc_id < VC_ID_WIDTH'(NUM_VC));
    endproperty

    a_legal_vc_east: assert property (p_legal_vc_east)
        else $error("noc_router_datapath: flit arrived on EAST with an illegal vc_id");


    property p_legal_vc_west;
        @(posedge clk) disable iff (rst)
        in_valid_west |-> (in_flit_west.vc_id < VC_ID_WIDTH'(NUM_VC));
    endproperty

    a_legal_vc_west: assert property (p_legal_vc_west)
        else $error("noc_router_datapath: flit arrived on WEST with an illegal vc_id");


    property p_legal_vc_local;
        @(posedge clk) disable iff (rst)
        in_valid_local |-> (in_flit_local.vc_id < VC_ID_WIDTH'(NUM_VC));
    endproperty

    a_legal_vc_local: assert property (p_legal_vc_local)
        else $error("noc_router_datapath: flit arrived on LOCAL with an illegal vc_id");

endmodule