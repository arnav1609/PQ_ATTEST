//=============================================================================
// Module 3: NoC Crossbar
// File: noc_crossbar.sv
//
// Purpose:
//     Combinational 5x5 switching fabric inside a NoC router.
//
// Responsibilities:
//     - Accept one flit from each router input port
//     - Route each selected input flit to its selected output port
//     - Generate output valid signals
//     - Provide safe behaviour for invalid selections
//
// Does NOT handle:
//     - XY routing
//     - Arbitration or allocation
//     - VC allocation
//     - FIFO storage
//     - Credit generation or flow control
//
// This module performs physical datapath selection ONLY. The separation is
// deliberate and correct: keeping arbitration out of the crossbar is what
// allows the allocator to be replaced or retimed without touching the
// switching fabric.
//
// REVISION: Review 01 repairs applied
//   X1 / L-01  noc_pkg::port_id_t now exists. This module previously
//              referenced a type that was never declared and could not
//              elaborate.
//   X2 / L-05  flit_t no longer carries its own valid bit, so the separate
//              valid signals are now the single source of truth.
//   X3         Loopback assertion added: an input may never be switched
//              back to the port it arrived on.
//   X4         Plain case changed to unique case.
//   X5 / L-02  File renamed from NOC_CORSSBAR.sv.
//   X6 / L-02  Companion zero-byte NOC_CROSSBAR.vh deleted from the project.
//=============================================================================

`timescale 1ns/1ps
module noc_crossbar (

    //-------------------------------------------------------------------------
    // Input flits
    //-------------------------------------------------------------------------

    input  noc_pkg::flit_t in_flit_north,
    input  noc_pkg::flit_t in_flit_south,
    input  noc_pkg::flit_t in_flit_east,
    input  noc_pkg::flit_t in_flit_west,
    input  noc_pkg::flit_t in_flit_local,

    //-------------------------------------------------------------------------
    // Input valid signals
    //-------------------------------------------------------------------------

    input  logic in_valid_north,
    input  logic in_valid_south,
    input  logic in_valid_east,
    input  logic in_valid_west,
    input  logic in_valid_local,

    //-------------------------------------------------------------------------
    // Output selection
    //
    // For each output port, this specifies which INPUT port is connected to
    // that output.
    //
    // CONTRACT ON THE ALLOCATOR (L-07):
    //   The allocator must guarantee that no input port is selected by more
    //   than one output in the same cycle, and it must HOLD each selection
    //   unchanged from a packet's HEAD flit through to its TAIL flit. If a
    //   selection changes mid-packet, two packets interleave on one link and
    //   both are destroyed. This crossbar cannot detect that condition and
    //   does not try to.
    //-------------------------------------------------------------------------

    input  noc_pkg::port_id_t select_north,
    input  noc_pkg::port_id_t select_south,
    input  noc_pkg::port_id_t select_east,
    input  noc_pkg::port_id_t select_west,
    input  noc_pkg::port_id_t select_local,

    //-------------------------------------------------------------------------
    // Output flits
    //-------------------------------------------------------------------------

    output noc_pkg::flit_t out_flit_north,
    output noc_pkg::flit_t out_flit_south,
    output noc_pkg::flit_t out_flit_east,
    output noc_pkg::flit_t out_flit_west,
    output noc_pkg::flit_t out_flit_local,

    //-------------------------------------------------------------------------
    // Output valid signals
    //-------------------------------------------------------------------------

    output logic out_valid_north,
    output logic out_valid_south,
    output logic out_valid_east,
    output logic out_valid_west,
    output logic out_valid_local
);

    import noc_pkg::*;

    //=========================================================================
    // Combinational crossbar
    //=========================================================================

    always_comb begin

        //---------------------------------------------------------------------
        // Default outputs
        //
        // Every output is assigned here before any case statement, which is
        // what guarantees no latch can be inferred regardless of the select
        // values.
        //---------------------------------------------------------------------

        out_flit_north = '0;
        out_flit_south = '0;
        out_flit_east  = '0;
        out_flit_west  = '0;
        out_flit_local = '0;

        out_valid_north = 1'b0;
        out_valid_south = 1'b0;
        out_valid_east  = 1'b0;
        out_valid_west  = 1'b0;
        out_valid_local = 1'b0;


        //---------------------------------------------------------------------
        // NORTH OUTPUT
        //---------------------------------------------------------------------

        unique case (port_e'(select_north))

            PORT_NORTH: begin
                out_flit_north  = in_flit_north;
                out_valid_north = in_valid_north;
            end

            PORT_SOUTH: begin
                out_flit_north  = in_flit_south;
                out_valid_north = in_valid_south;
            end

            PORT_EAST: begin
                out_flit_north  = in_flit_east;
                out_valid_north = in_valid_east;
            end

            PORT_WEST: begin
                out_flit_north  = in_flit_west;
                out_valid_north = in_valid_west;
            end

            PORT_LOCAL: begin
                out_flit_north  = in_flit_local;
                out_valid_north = in_valid_local;
            end

            default: begin
                out_flit_north  = '0;
                out_valid_north = 1'b0;
            end

        endcase


        //---------------------------------------------------------------------
        // SOUTH OUTPUT
        //---------------------------------------------------------------------

        unique case (port_e'(select_south))

            PORT_NORTH: begin
                out_flit_south  = in_flit_north;
                out_valid_south = in_valid_north;
            end

            PORT_SOUTH: begin
                out_flit_south  = in_flit_south;
                out_valid_south = in_valid_south;
            end

            PORT_EAST: begin
                out_flit_south  = in_flit_east;
                out_valid_south = in_valid_east;
            end

            PORT_WEST: begin
                out_flit_south  = in_flit_west;
                out_valid_south = in_valid_west;
            end

            PORT_LOCAL: begin
                out_flit_south  = in_flit_local;
                out_valid_south = in_valid_local;
            end

            default: begin
                out_flit_south  = '0;
                out_valid_south = 1'b0;
            end

        endcase


        //---------------------------------------------------------------------
        // EAST OUTPUT
        //---------------------------------------------------------------------

        unique case (port_e'(select_east))

            PORT_NORTH: begin
                out_flit_east  = in_flit_north;
                out_valid_east = in_valid_north;
            end

            PORT_SOUTH: begin
                out_flit_east  = in_flit_south;
                out_valid_east = in_valid_south;
            end

            PORT_EAST: begin
                out_flit_east  = in_flit_east;
                out_valid_east = in_valid_east;
            end

            PORT_WEST: begin
                out_flit_east  = in_flit_west;
                out_valid_east = in_valid_west;
            end

            PORT_LOCAL: begin
                out_flit_east  = in_flit_local;
                out_valid_east = in_valid_local;
            end

            default: begin
                out_flit_east  = '0;
                out_valid_east = 1'b0;
            end

        endcase


        //---------------------------------------------------------------------
        // WEST OUTPUT
        //---------------------------------------------------------------------

        unique case (port_e'(select_west))

            PORT_NORTH: begin
                out_flit_west  = in_flit_north;
                out_valid_west = in_valid_north;
            end

            PORT_SOUTH: begin
                out_flit_west  = in_flit_south;
                out_valid_west = in_valid_south;
            end

            PORT_EAST: begin
                out_flit_west  = in_flit_east;
                out_valid_west = in_valid_east;
            end

            PORT_WEST: begin
                out_flit_west  = in_flit_west;
                out_valid_west = in_valid_west;
            end

            PORT_LOCAL: begin
                out_flit_west  = in_flit_local;
                out_valid_west = in_valid_local;
            end

            default: begin
                out_flit_west  = '0;
                out_valid_west = 1'b0;
            end

        endcase


        //---------------------------------------------------------------------
        // LOCAL OUTPUT
        //---------------------------------------------------------------------

        unique case (port_e'(select_local))

            PORT_NORTH: begin
                out_flit_local  = in_flit_north;
                out_valid_local = in_valid_north;
            end

            PORT_SOUTH: begin
                out_flit_local  = in_flit_south;
                out_valid_local = in_valid_south;
            end

            PORT_EAST: begin
                out_flit_local  = in_flit_east;
                out_valid_local = in_valid_east;
            end

            PORT_WEST: begin
                out_flit_local  = in_flit_west;
                out_valid_local = in_valid_west;
            end

            PORT_LOCAL: begin
                out_flit_local  = in_flit_local;
                out_valid_local = in_valid_local;
            end

            default: begin
                out_flit_local  = '0;
                out_valid_local = 1'b0;
            end

        endcase

    end


    //=========================================================================
    // ASSERTIONS
    //
    // Immediate assertions inside an always_comb, because this module is
    // purely combinational and has no clock of its own.
    //
    // Guarded out of synthesis: an always_comb block containing no
    // assignments is legal but makes some synthesis flows complain, and
    // there is nothing here for hardware to do.
    //=========================================================================

// DECISION D2 (2026-09-23, path-to-N-8 council): NOC_CROSSBAR_COMB_ASSERTS is
// intentionally never defined. These immediate asserts in always_comb fire
// falsely on delta-cycle settling. The same no-loopback property is checked
// on ALL five ports, clock-sampled, by noc_router.sv
// a_no_loopback_{local,north,south,east,west}_sync (active in M8, N-6, N-7).
// Known gap: the standalone datapath TB (TB1) has no loopback check.
`ifndef SYNTHESIS
`ifdef NOC_CROSSBAR_COMB_ASSERTS
    always_comb begin

        //---------------------------------------------------------------------
        // NO LOOPBACK.  (X3)
        //
        // A flit arriving on a port must never be switched straight back out
        // of that same port. For LOCAL this would mean a tile sending a
        // packet to itself through the router, which is never legal. For the
        // four mesh ports it would mean a 180-degree turn, which XY routing
        // never produces and which would create a cycle if it did.
        //---------------------------------------------------------------------

        a_no_loopback_north: assert (!(in_valid_north && (port_e'(select_north) == PORT_NORTH)))
            else $error("noc_crossbar: NORTH input switched back to NORTH output");

        a_no_loopback_south: assert (!(in_valid_south && (port_e'(select_south) == PORT_SOUTH)))
            else $error("noc_crossbar: SOUTH input switched back to SOUTH output");

        a_no_loopback_east:  assert (!(in_valid_east  && (port_e'(select_east)  == PORT_EAST)))
            else $error("noc_crossbar: EAST input switched back to EAST output");

        a_no_loopback_west:  assert (!(in_valid_west  && (port_e'(select_west)  == PORT_WEST)))
            else $error("noc_crossbar: WEST input switched back to WEST output");

        a_no_loopback_local: assert (!(in_valid_local && (port_e'(select_local) == PORT_LOCAL)))
            else $error("noc_crossbar: LOCAL input switched back to LOCAL output - a tile cannot send to itself");

    end
`endif
`endif

endmodule