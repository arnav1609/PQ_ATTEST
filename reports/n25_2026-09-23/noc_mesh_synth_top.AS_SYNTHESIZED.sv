`timescale 1ns/1ps
// N-2.5 probe: 3-pin wrapper so the 6-router mesh can be placed & routed
// without synthesis trimming it. LFSRs drive every tile input; all outputs
// are XOR-folded to the led pin. Measures area/timing only.
module noc_mesh_synth_top (
    input  logic clk,
    input  logic rst,
    output logic led
);
    import noc_pkg::*;

    localparam int N  = NUM_TILES;
    localparam int FW = $bits(flit_t);

    logic [1:0] rst_sync;                       // button -> sync active-HIGH reset
    always_ff @(posedge clk) rst_sync <= {rst_sync[0], rst};
    wire rst_s = rst_sync[1];

    flit_t [N-1:0] in_flit, out_flit;
    logic  [N-1:0] in_valid, in_ready, out_valid, out_ready;

    genvar g;
    generate
        for (g = 0; g < N; g++) begin : GEN_SRC
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
        .clk(clk), .rst(rst_s),
        .tile_in_flit(in_flit),   .tile_in_valid(in_valid),   .tile_in_ready(in_ready),
        .tile_out_flit(out_flit), .tile_out_valid(out_valid), .tile_out_ready(out_ready)
    );

    logic fold_q;
    always_ff @(posedge clk) begin
        if (rst_s) fold_q <= 1'b0;
        else       fold_q <= fold_q ^ (^out_flit) ^ (^out_valid) ^ (^in_ready);
    end
    assign led = fold_q;
endmodule