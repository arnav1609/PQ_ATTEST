`timescale 1ns/1ps
//=============================================================================
// Module : noc_mesh_3x2
// File   : noc_mesh_3x2.sv
//
// PQ-Attest NoC - synthesizable 3x2 mesh of six noc_router (M8/M9) instances.
//
// Provenance: structure lifted from the N-7 harness tb_noc_mesh.sv (GEN_R and
// link/credit wiring, DIAG-EXP-1 plain-signal form be383be, 1761/0/0, 0 SVA
// lines). No router logic is added here: wiring plus the optional LINK_PIPE
// register stage on router->router data links (see below).
//
// Topology (tile index i = y*MESH_X + x, same order as noc_pkg::tile_id_e and
// noc_pkg::tile_to_coord):
//
//        0 CPU0 (0,0) ---- 1 CPU1 (1,0) ---- 2 MEMORY (2,0)
//             |                  |                  |
//        3 CRYPTO (0,1) -- 4 RoT (1,1) ----- 5 SPOOF (2,1)
//
// Flow control (7c, docs/decisions/7c-flow-control.md):
//   - router <-> router : credits. credit_out of the downstream router's
//     input port feeds credit_return of the upstream router's output port.
//   - router <-> tile   : ready/valid.
//       tile_in_*  : transfer = tile_in_valid[i]  && tile_in_ready[i]
//       tile_out_* : transfer = tile_out_valid[i] && tile_out_ready[i]
//     credit_return[PORT_LOCAL] is ignored by the router (tied 0 here).
//
// Edge ports (no neighbour) are hard tied off: flit '0, valid 0, credit 0.
//
// LINK_PIPE (D7 timing fix, 2026-09-23; default 1 = the configuration that is
// synthesized and must be verified):
//   1 : every router->router DATA link (flit + valid) passes through one
//       register stage (lk_*). Credits are NOT piped: credit_out is already a
//       registered pulse (noc_fifo.credit_valid).
//   0 : combinational links (the pre-D7 mesh, N-7 1762/0 baseline).
//   Why: N-2.5 routed timing (reports/n25_2026-09-23) failed at 50 MHz with
//   WNS -1.301 ns; the critical path ran from R4's input-FIFO head through its
//   allocator and crossbar straight into R1's input-FIFO write enable - two
//   routers in one cycle. The stage cuts every path at the router boundary.
//   Credit correctness: the upstream counter is decremented at SEND (the
//   cycle the flit enters lk_*), so a flit in the link stage already owns a
//   downstream slot - no overflow is possible and no extra buffering exists.
//   Cost: +1 cycle per router->router hop; credit round trip 3 -> 4 cycles,
//   which still equals VC depth 4, so one VC can still sustain 1 flit/cycle
//   (zero slack: any further link latency would need depth 5).
//
// Reset: active-HIGH synchronous rst (NoC lane convention). The crypto lane
// is active-LOW rst_n - bridge at SoC integration (N-14), not here.
//
// Port form: packed arrays indexed by tile. Inside, every router port is
// connected to a plain per-instance signal (never an unpacked-array element),
// the form that removed the XSim SVA artefact in DIAG-EXP-1.
//=============================================================================

module noc_mesh_3x2 #(
    parameter bit LINK_PIPE = 1'b1
) (
    input  logic                                   clk,
    input  logic                                   rst,

    // Tile -> router (LOCAL input), ready/valid
    input  noc_pkg::flit_t [noc_pkg::NUM_TILES-1:0] tile_in_flit,
    input  logic           [noc_pkg::NUM_TILES-1:0] tile_in_valid,
    output logic           [noc_pkg::NUM_TILES-1:0] tile_in_ready,

    // Router -> tile (LOCAL output), ready/valid
    output noc_pkg::flit_t [noc_pkg::NUM_TILES-1:0] tile_out_flit,
    output logic           [noc_pkg::NUM_TILES-1:0] tile_out_valid,
    input  logic           [noc_pkg::NUM_TILES-1:0] tile_out_ready
);

    import noc_pkg::*;

    localparam int N = NUM_TILES;

    // Elaboration guard: the link table below is written for exactly 3x2.
    // synthesis translate_off
    initial begin
        if ((MESH_X != 3) || (MESH_Y != 2) || (NUM_TILES != 6))
            $fatal(1, "noc_mesh_3x2: link table is hand-written for 3x2, got %0dx%0d",
                   MESH_X, MESH_Y);
    end
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // Inter-router nets. Names match tb_noc_mesh.sv so the N-7 harness can
    // observe them hierarchically (observation only).
    //-------------------------------------------------------------------------
    flit_t out_n [0:N-1], out_s [0:N-1];
    flit_t out_e [0:N-1], out_w [0:N-1], out_l [0:N-1];
    logic  out_v_n [0:N-1], out_v_s [0:N-1];
    logic  out_v_e [0:N-1], out_v_w [0:N-1], out_v_l [0:N-1];

    flit_t in_n [0:N-1], in_s [0:N-1];
    flit_t in_e [0:N-1], in_w [0:N-1];
    logic  in_v_n [0:N-1], in_v_s [0:N-1];
    logic  in_v_e [0:N-1], in_v_w [0:N-1];

    // Link stage outputs (= out_* delayed one cycle when LINK_PIPE, else = out_*).
    // The data-link table below reads lk_*, never out_*.
    flit_t lk_n [0:N-1], lk_s [0:N-1], lk_e [0:N-1], lk_w [0:N-1];
    logic  lk_v_n [0:N-1], lk_v_s [0:N-1], lk_v_e [0:N-1], lk_v_w [0:N-1];

    // credit_return[router][output_port][VC]; credit_out_w[router][input_port][VC]
    logic [NUM_VC-1:0] credit_return [0:N-1][NUM_PORTS];
    logic [NUM_VC-1:0] credit_out_w  [0:N-1][NUM_PORTS];

    //-------------------------------------------------------------------------
    // Six routers
    //-------------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : GEN_R
            coord_t            p_coord;
            flit_t             p_in_n, p_in_s, p_in_e, p_in_w, p_in_l;
            logic              p_v_n,  p_v_s,  p_v_e,  p_v_w,  p_v_l;
            logic              p_rdy_l;
            flit_t             p_out_n, p_out_s, p_out_e, p_out_w, p_out_l;
            logic              p_ov_n,  p_ov_s,  p_ov_e,  p_ov_w,  p_ov_l;
            logic              p_ordy_l;
            logic [NUM_VC-1:0] p_cr_n, p_cr_s, p_cr_e, p_cr_w, p_cr_l;
            logic [NUM_VC-1:0] p_co_n, p_co_s, p_co_e, p_co_w, p_co_l;
            logic [NUM_VC-1:0] p_cr [NUM_PORTS];
            logic [NUM_VC-1:0] p_co [NUM_PORTS];

            // i = y*MESH_X + x  (matches noc_pkg::tile_to_coord order)
            assign p_coord.x = COORD_WIDTH'(g % MESH_X);
            assign p_coord.y = COORD_WIDTH'(g / MESH_X);

            assign p_in_n = in_n[g];          assign p_v_n = in_v_n[g];
            assign p_in_s = in_s[g];          assign p_v_s = in_v_s[g];
            assign p_in_e = in_e[g];          assign p_v_e = in_v_e[g];
            assign p_in_w = in_w[g];          assign p_v_w = in_v_w[g];
            assign p_in_l = tile_in_flit[g];  assign p_v_l = tile_in_valid[g];
            assign p_ordy_l = tile_out_ready[g];

            assign p_cr_n = credit_return[g][PORT_NORTH];
            assign p_cr_s = credit_return[g][PORT_SOUTH];
            assign p_cr_e = credit_return[g][PORT_EAST];
            assign p_cr_w = credit_return[g][PORT_WEST];
            assign p_cr_l = credit_return[g][PORT_LOCAL];
            assign p_cr[PORT_NORTH] = p_cr_n;
            assign p_cr[PORT_SOUTH] = p_cr_s;
            assign p_cr[PORT_EAST]  = p_cr_e;
            assign p_cr[PORT_WEST]  = p_cr_w;
            assign p_cr[PORT_LOCAL] = p_cr_l;

            noc_router r (
                .clk(clk),
                .rst(rst),
                .current_coord(p_coord),

                .in_flit_north(p_in_n), .in_valid_north(p_v_n),
                .in_flit_south(p_in_s), .in_valid_south(p_v_s),
                .in_flit_east (p_in_e), .in_valid_east (p_v_e),
                .in_flit_west (p_in_w), .in_valid_west (p_v_w),
                .in_flit_local(p_in_l), .in_valid_local(p_v_l),
                .in_ready_local(p_rdy_l),

                .credit_return(p_cr),
                .credit_out(p_co),

                .out_flit_north(p_out_n), .out_valid_north(p_ov_n),
                .out_flit_south(p_out_s), .out_valid_south(p_ov_s),
                .out_flit_east (p_out_e), .out_valid_east (p_ov_e),
                .out_flit_west (p_out_w), .out_valid_west (p_ov_w),
                .out_flit_local(p_out_l), .out_valid_local(p_ov_l),
                .out_ready_local(p_ordy_l)
            );

            assign tile_in_ready[g]  = p_rdy_l;
            assign tile_out_flit[g]  = p_out_l;
            assign tile_out_valid[g] = p_ov_l;

            assign out_n[g] = p_out_n;   assign out_v_n[g] = p_ov_n;
            assign out_s[g] = p_out_s;   assign out_v_s[g] = p_ov_s;
            assign out_e[g] = p_out_e;   assign out_v_e[g] = p_ov_e;
            assign out_w[g] = p_out_w;   assign out_v_w[g] = p_ov_w;
            assign out_l[g] = p_out_l;   assign out_v_l[g] = p_ov_l;

            //-----------------------------------------------------------------
            // Link stage for the four mesh outputs. Plain per-instance
            // signals (DIAG-EXP-1 form). Edge outputs are piped too; their
            // registers have no load and are trimmed by synthesis.
            //-----------------------------------------------------------------
            flit_t q_n, q_s, q_e, q_w;
            logic  qv_n, qv_s, qv_e, qv_w;
            if (LINK_PIPE) begin : G_LINK_REG
                always_ff @(posedge clk) begin
                    if (rst) begin
                        q_n <= '0;  q_s <= '0;  q_e <= '0;  q_w <= '0;
                        qv_n <= 1'b0; qv_s <= 1'b0; qv_e <= 1'b0; qv_w <= 1'b0;
                    end
                    else begin
                        q_n <= p_out_n;  qv_n <= p_ov_n;
                        q_s <= p_out_s;  qv_s <= p_ov_s;
                        q_e <= p_out_e;  qv_e <= p_ov_e;
                        q_w <= p_out_w;  qv_w <= p_ov_w;
                    end
                end
            end
            else begin : G_LINK_WIRE
                assign q_n = p_out_n;  assign qv_n = p_ov_n;
                assign q_s = p_out_s;  assign qv_s = p_ov_s;
                assign q_e = p_out_e;  assign qv_e = p_ov_e;
                assign q_w = p_out_w;  assign qv_w = p_ov_w;
            end
            assign lk_n[g] = q_n;   assign lk_v_n[g] = qv_n;
            assign lk_s[g] = q_s;   assign lk_v_s[g] = qv_s;
            assign lk_e[g] = q_e;   assign lk_v_e[g] = qv_e;
            assign lk_w[g] = q_w;   assign lk_v_w[g] = qv_w;

            assign p_co_n = p_co[PORT_NORTH];
            assign p_co_s = p_co[PORT_SOUTH];
            assign p_co_e = p_co[PORT_EAST];
            assign p_co_w = p_co[PORT_WEST];
            assign p_co_l = p_co[PORT_LOCAL];
            assign credit_out_w[g][PORT_NORTH] = p_co_n;
            assign credit_out_w[g][PORT_SOUTH] = p_co_s;
            assign credit_out_w[g][PORT_EAST]  = p_co_e;
            assign credit_out_w[g][PORT_WEST]  = p_co_w;
            assign credit_out_w[g][PORT_LOCAL] = p_co_l;
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Data links (table from tb_noc_mesh.sv, 1761/0/0; sources now lk_*)
    //-------------------------------------------------------------------------
    // Horizontal: EAST output -> neighbour WEST input, and back.
    assign in_w[1] = lk_e[0]; assign in_v_w[1] = lk_v_e[0];
    assign in_e[0] = lk_w[1]; assign in_v_e[0] = lk_v_w[1];

    assign in_w[2] = lk_e[1]; assign in_v_w[2] = lk_v_e[1];
    assign in_e[1] = lk_w[2]; assign in_v_e[1] = lk_v_w[2];

    assign in_w[4] = lk_e[3]; assign in_v_w[4] = lk_v_e[3];
    assign in_e[3] = lk_w[4]; assign in_v_e[3] = lk_v_w[4];

    assign in_w[5] = lk_e[4]; assign in_v_w[5] = lk_v_e[4];
    assign in_e[4] = lk_w[5]; assign in_v_e[4] = lk_v_w[5];

    // Vertical: SOUTH output -> neighbour NORTH input, and back.
    assign in_n[3] = lk_s[0]; assign in_v_n[3] = lk_v_s[0];
    assign in_s[0] = lk_n[3]; assign in_v_s[0] = lk_v_n[3];

    assign in_n[4] = lk_s[1]; assign in_v_n[4] = lk_v_s[1];
    assign in_s[1] = lk_n[4]; assign in_v_s[1] = lk_v_n[4];

    assign in_n[5] = lk_s[2]; assign in_v_n[5] = lk_v_s[2];
    assign in_s[2] = lk_n[5]; assign in_v_s[2] = lk_v_n[5];

    // Edge inputs with no neighbour: hard tie-off.
    assign in_n[0] = '0; assign in_v_n[0] = 1'b0;
    assign in_n[1] = '0; assign in_v_n[1] = 1'b0;
    assign in_n[2] = '0; assign in_v_n[2] = 1'b0;

    assign in_s[3] = '0; assign in_v_s[3] = 1'b0;
    assign in_s[4] = '0; assign in_v_s[4] = 1'b0;
    assign in_s[5] = '0; assign in_v_s[5] = 1'b0;

    assign in_w[0] = '0; assign in_v_w[0] = 1'b0;
    assign in_w[3] = '0; assign in_v_w[3] = 1'b0;

    assign in_e[2] = '0; assign in_v_e[2] = 1'b0;
    assign in_e[5] = '0; assign in_v_e[5] = 1'b0;

    //-------------------------------------------------------------------------
    // Credit links (copied from tb_noc_mesh.sv). Whole VC vector driven once
    // per output port. Edge outputs and LOCAL get 0 (LOCAL credit is internal
    // to the router under 7c).
    //-------------------------------------------------------------------------
    assign credit_return[0][PORT_NORTH] = '0;
    assign credit_return[0][PORT_SOUTH] = credit_out_w[3][PORT_NORTH];
    assign credit_return[0][PORT_EAST]  = credit_out_w[1][PORT_WEST];
    assign credit_return[0][PORT_WEST]  = '0;

    assign credit_return[1][PORT_NORTH] = '0;
    assign credit_return[1][PORT_SOUTH] = credit_out_w[4][PORT_NORTH];
    assign credit_return[1][PORT_EAST]  = credit_out_w[2][PORT_WEST];
    assign credit_return[1][PORT_WEST]  = credit_out_w[0][PORT_EAST];

    assign credit_return[2][PORT_NORTH] = '0;
    assign credit_return[2][PORT_SOUTH] = credit_out_w[5][PORT_NORTH];
    assign credit_return[2][PORT_EAST]  = '0;
    assign credit_return[2][PORT_WEST]  = credit_out_w[1][PORT_EAST];

    assign credit_return[3][PORT_NORTH] = credit_out_w[0][PORT_SOUTH];
    assign credit_return[3][PORT_SOUTH] = '0;
    assign credit_return[3][PORT_EAST]  = credit_out_w[4][PORT_WEST];
    assign credit_return[3][PORT_WEST]  = '0;

    assign credit_return[4][PORT_NORTH] = credit_out_w[1][PORT_SOUTH];
    assign credit_return[4][PORT_SOUTH] = '0;
    assign credit_return[4][PORT_EAST]  = credit_out_w[5][PORT_WEST];
    assign credit_return[4][PORT_WEST]  = credit_out_w[3][PORT_EAST];

    assign credit_return[5][PORT_NORTH] = credit_out_w[2][PORT_SOUTH];
    assign credit_return[5][PORT_SOUTH] = '0;
    assign credit_return[5][PORT_EAST]  = '0;
    assign credit_return[5][PORT_WEST]  = credit_out_w[4][PORT_EAST];

    assign credit_return[0][PORT_LOCAL] = '0;
    assign credit_return[1][PORT_LOCAL] = '0;
    assign credit_return[2][PORT_LOCAL] = '0;
    assign credit_return[3][PORT_LOCAL] = '0;
    assign credit_return[4][PORT_LOCAL] = '0;
    assign credit_return[5][PORT_LOCAL] = '0;

endmodule
