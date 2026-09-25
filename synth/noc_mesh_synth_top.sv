`timescale 1ns/1ps
//=============================================================================
// Module : noc_mesh_synth_top           (N-2.5 synthesis/implementation probe)
// File   : synth/noc_mesh_synth_top.sv  (synth-only helper, NOT in the project)
//
// Purpose: give noc_mesh_3x2 a 3-pin boundary (clk, rst, led) so it can be
// placed and routed on the real xc7a100tcsg324-1, WITHOUT letting synthesis
// trim the mesh. Council decision D3/D3a (2026-09-23).
//
// Anti-trim structure:
//   - every tile LOCAL input (flit, valid) and every tile_out_ready is driven
//     from a free-running per-tile LFSR (never constant);
//   - every mesh output (tile_out_flit, tile_out_valid, tile_in_ready) is
//     XOR-folded into one register that drives the led pin.
//   So every router's datapath lies in the cone of an observable output.
//   Edge ports tied off inside noc_mesh_3x2 ARE trimmed - legitimately, the
//   real mesh has the same constants.
//
// The traffic is garbage by design (random dest/type/vc). This module
// measures AREA and TIMING only; functional correctness is proven by the
// N-6/N-7 simulations, not here.
//
// Reset: rst pin is synchronised (2 FF) to an active-HIGH synchronous reset,
// matching the NoC lane convention.
//=============================================================================
module noc_mesh_synth_top (
    input  logic clk,
    input  logic rst,
    output logic led
);
    import noc_pkg::*;

    localparam int N  = NUM_TILES;
    localparam int FW = $bits(flit_t);

    // reset synchroniser
    logic [1:0] rst_sync;
    always_ff @(posedge clk) rst_sync <= {rst_sync[0], rst};
    wire rst_s = rst_sync[1];

    flit_t [N-1:0] in_flit, out_flit;
    logic  [N-1:0] in_valid, in_ready, out_valid, out_ready;

    genvar g;
    generate
        for (g = 0; g < N; g++) begin : GEN_SRC
            // 40-bit Fibonacci LFSR, taps 40,38,21,19 (maximal-length polynomial
            // commonly listed in Xilinx XAPP052; exact period is irrelevant here,
            // only non-constancy matters).
            logic [39:0] lfsr;
            always_ff @(posedge clk) begin
                if (rst_s) lfsr <= 40'hA5C3_0F1E_00 ^ 40'(g * 32'h9E37_79B9 + 1);
                else       lfsr <= {lfsr[38:0], lfsr[39] ^ lfsr[37] ^ lfsr[20] ^ lfsr[18]};
            end
            assign in_flit[g]   = flit_t'(lfsr[FW-1:0]);
            assign in_valid[g]  = lfsr[39];
            assign out_ready[g] = lfsr[38];
        end
    endgenerate

    noc_mesh_3x2 u_mesh (
        .clk           (clk),
        .rst           (rst_s),
        .tile_in_flit  (in_flit),
        .tile_in_valid (in_valid),
        .tile_in_ready (in_ready),
        .tile_out_flit (out_flit),
        .tile_out_valid(out_valid),
        .tile_out_ready(out_ready)
    );

    // Observability fold
    logic fold_q;
    always_ff @(posedge clk) begin
        if (rst_s) fold_q <= 1'b0;
        else       fold_q <= fold_q ^ (^out_flit) ^ (^out_valid) ^ (^in_ready);
    end
    assign led = fold_q;

endmodule
