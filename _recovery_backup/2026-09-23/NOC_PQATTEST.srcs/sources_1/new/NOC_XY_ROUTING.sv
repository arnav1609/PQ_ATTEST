//=============================================================================
// Module 5: XY Routing
// File: noc_xy_routing.sv
//
// Purpose:
//     Deterministic dimension-order routing for the 3x2 NoC mesh.
//     Purely combinational. No clock, no reset, no state.
//
// Routing order:
//     1. Resolve X completely
//     2. Then resolve Y
//     3. LOCAL when the destination has been reached
//
// Coordinate convention:
//     y = 0 -> North / top row
//     y = 1 -> South / bottom row
//
// Therefore:
//     Dx > Cx -> EAST
//     Dx < Cx -> WEST
//     Dy > Cy -> SOUTH
//     Dy < Cy -> NORTH
//     equal   -> LOCAL
//
// WHY DIMENSION-ORDER ROUTING:
//     Resolving X before Y permits only the turns EAST->NORTH, EAST->SOUTH,
//     WEST->NORTH and WEST->SOUTH. The NORTH->EAST/WEST and SOUTH->EAST/WEST
//     turns become structurally impossible, which breaks every cycle in the
//     channel dependency graph. The routing function therefore cannot
//     deadlock.
//
//     This does NOT prove the NoC as a whole is deadlock-free. Protocol
//     deadlock, VC dependencies, allocator behaviour, credit management and
//     endpoint behaviour are separate arguments. See the VC notes in
//     noc_pkg.sv, in particular the one-outstanding-attestation invariant.
//
// REVISION: Review 01 repairs applied
//   X1 / L-01  noc_pkg::port_id_e did not exist. This module now uses
//              noc_pkg::port_id_t, matching the crossbar and the package.
//   X2         route_valid output added. An out-of-mesh destination used to
//              produce a confident but wrong direction; it is now reported.
//   X3         port_exists() check added as defence in depth.
//   X4 / L-02  File renamed from NOC_XYROUTING.sv.
//=============================================================================

`timescale 1ns/1ps
module noc_xy_routing (

    //-------------------------------------------------------------------------
    // Coordinates
    //
    // current_coord is the router's own position, normally tied to a
    // per-instance constant.
    // dest_coord comes from the head flit.
    //-------------------------------------------------------------------------

    input  noc_pkg::coord_t   current_coord,
    input  noc_pkg::coord_t   dest_coord,

    //-------------------------------------------------------------------------
    // Computed next hop
    //
    // Only meaningful when route_valid is asserted.
    //-------------------------------------------------------------------------

    output noc_pkg::port_id_t route_port,

    //-------------------------------------------------------------------------
    // Route validity
    //
    // 0 means the request is malformed and the packet MUST be dropped with
    // an error rather than forwarded.
    //
    // Deasserted when:
    //   - either coordinate lies outside the mesh, or
    //   - the computed port does not physically exist at this router.
    //
    // The second case cannot occur for a well-formed mesh and a correct XY
    // route, which is exactly why it is worth checking: if it ever fires,
    // something upstream is broken, and a caught fault is worth far more
    // than a flit switched into a port that is not there.
    //-------------------------------------------------------------------------

    output logic              route_valid
);

    import noc_pkg::*;

    //-------------------------------------------------------------------------
    // Coordinate sanity
    //
    // Both comparisons below are between unsigned vectors of equal width,
    // so no signed-comparison hazard exists.
    //-------------------------------------------------------------------------

    logic  coords_ok;
    port_e computed_port;

    //-------------------------------------------------------------------------
    // ROUTE COMPUTATION, QUALIFICATION AND CHECKING -- ONE SINGLE always_comb
    //
    // WHY THIS IS ONE BLOCK AND MUST STAY ONE BLOCK:
    //
    //   This was originally three separate processes: a continuous assign for
    //   coords_ok, an always_comb computing computed_port, and a second
    //   always_comb qualifying the outputs. Separate combinational processes
    //   have NO GUARANTEED EVALUATION ORDER.
    //
    //   When a coordinate changed, the qualify block could execute BEFORE the
    //   compute block had updated computed_port. route_port was then derived
    //   from a stale computed_port while the immediate assertion compared it
    //   against fresh coordinates -- and reported a routing failure that
    //   never physically occurred. It fired 4 times out of 4096+ evaluations,
    //   sporadically, exactly like the delta-cycle race it was.
    //
    //   Moving only the assertions into the qualify block did NOT fix it,
    //   because the race was one level further up: between COMPUTE and
    //   QUALIFY, not between QUALIFY and CHECK.
    //
    //   Collapsing all of it into a single procedural block makes evaluation
    //   atomic. Every value the checker sees is derived from the same input
    //   snapshot, so the race cannot exist.
    //
    //   The clocked SVA in the testbench always passed throughout, because
    //   clocked assertions sample in the preponed region and never observe
    //   intermediate combinational states. That disagreement between a
    //   clocked and an unclocked checker of the same property is what
    //   identified the race.
    //
    //   Latch safety is unaffected: computed_port, route_valid and route_port
    //   are all assigned on every path through the block.
    //-------------------------------------------------------------------------

    always_comb begin

        //---------------------------------------------------------------------
        // Coordinate sanity
        //---------------------------------------------------------------------

        coords_ok = valid_coord(current_coord) && valid_coord(dest_coord);

        //---------------------------------------------------------------------
        // Dimension-order route computation
        //---------------------------------------------------------------------

        computed_port = PORT_LOCAL;

        if (dest_coord.x > current_coord.x) begin
            computed_port = PORT_EAST;
        end
        else if (dest_coord.x < current_coord.x) begin
            computed_port = PORT_WEST;
        end
        else if (dest_coord.y > current_coord.y) begin
            computed_port = PORT_SOUTH;
        end
        else if (dest_coord.y < current_coord.y) begin
            computed_port = PORT_NORTH;
        end
        else begin
            computed_port = PORT_LOCAL;
        end

        //---------------------------------------------------------------------
        // Output qualification
        //
        // On an invalid request the port is forced to LOCAL rather than left
        // at whatever the arithmetic produced. LOCAL is the safe choice: it
        // keeps a malformed packet inside this router where the network
        // interface can raise an error, instead of pushing it further into
        // the mesh.
        //---------------------------------------------------------------------

        if (coords_ok && port_exists(current_coord, computed_port)) begin
            route_valid = 1'b1;
            route_port  = port_id_t'(computed_port);
        end
        else begin
            route_valid = 1'b0;
            route_port  = port_id_t'(PORT_LOCAL);
        end

        //---------------------------------------------------------------------
        // Immediate assertions, evaluated on the same atomic snapshot
        //---------------------------------------------------------------------

        // A packet must never be routed LOCAL unless it has actually arrived.
        // This separates "delivered" from "silently misrouted to the local
        // port because something upstream was malformed".
        a_local_only_at_destination:
            assert (!(route_valid && (port_e'(route_port) == PORT_LOCAL))
                    || (dest_coord == current_coord))
            else $error("noc_xy_routing: LOCAL route computed but destination is not this router");

        // A valid route must never select a port that does not exist here.
        a_route_port_exists:
            assert (!route_valid || port_exists(current_coord, port_e'(route_port)))
            else $error("noc_xy_routing: computed port does not exist at this router");

    end


    //=========================================================================
    // ASSERTIONS
    //
    // Immediate assertions, because this module is combinational and has no
    // clock of its own. Guarded out of synthesis.
    //=========================================================================

    // Assertions moved into the output-qualification always_comb above.
    // See the comment there for why a separate checker block was wrong.

endmodule