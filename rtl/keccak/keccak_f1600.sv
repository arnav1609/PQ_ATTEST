module keccak_f1600 (
    input  logic [1599:0] state_in,
    output logic [1599:0] state_out
);

    logic [63:0] A [0:4][0:4];
    logic [63:0] B [0:4][0:4];
    logic [63:0] C [0:4];
    logic [63:0] D [0:4];

    integer x;
    integer y;
    integer round;


    // =========================================================
    // 64-bit rotate-left
    // =========================================================

    function automatic [63:0] rotl64;
        input [63:0] value;
        input integer shift;

        begin
            if (shift == 0)
                rotl64 = value;
            else
                rotl64 = (value << shift) |
                         (value >> (64 - shift));
        end
    endfunction


    // =========================================================
    // Keccak rotation offsets
    // =========================================================

    function automatic integer rho_offset;
        input integer ix;
        input integer iy;

        begin

            case (ix)

                0: begin
                    case (iy)
                        0: rho_offset = 0;
                        1: rho_offset = 36;
                        2: rho_offset = 3;
                        3: rho_offset = 41;
                        4: rho_offset = 18;
                    endcase
                end

                1: begin
                    case (iy)
                        0: rho_offset = 1;
                        1: rho_offset = 44;
                        2: rho_offset = 10;
                        3: rho_offset = 45;
                        4: rho_offset = 2;
                    endcase
                end

                2: begin
                    case (iy)
                        0: rho_offset = 62;
                        1: rho_offset = 6;
                        2: rho_offset = 43;
                        3: rho_offset = 15;
                        4: rho_offset = 61;
                    endcase
                end

                3: begin
                    case (iy)
                        0: rho_offset = 28;
                        1: rho_offset = 55;
                        2: rho_offset = 25;
                        3: rho_offset = 21;
                        4: rho_offset = 56;
                    endcase
                end

                4: begin
                    case (iy)
                        0: rho_offset = 27;
                        1: rho_offset = 20;
                        2: rho_offset = 39;
                        3: rho_offset = 8;
                        4: rho_offset = 14;
                    endcase
                end

            endcase

        end
    endfunction


    // =========================================================
    // Keccak round constants
    //
    // Function used instead of an unpacked parameter array
    // for compatibility with Icarus Verilog.
    // =========================================================

    function automatic [63:0] round_constant;
        input integer r;

        begin

            case (r)

                0:  round_constant = 64'h0000000000000001;
                1:  round_constant = 64'h0000000000008082;
                2:  round_constant = 64'h800000000000808A;
                3:  round_constant = 64'h8000000080008000;
                4:  round_constant = 64'h000000000000808B;
                5:  round_constant = 64'h0000000080000001;
                6:  round_constant = 64'h8000000080008081;
                7:  round_constant = 64'h8000000000008009;
                8:  round_constant = 64'h000000000000008A;
                9:  round_constant = 64'h0000000000000088;
                10: round_constant = 64'h0000000080008009;
                11: round_constant = 64'h000000008000000A;
                12: round_constant = 64'h000000008000808B;
                13: round_constant = 64'h800000000000008B;
                14: round_constant = 64'h8000000000008089;
                15: round_constant = 64'h8000000000008003;
                16: round_constant = 64'h8000000000008002;
                17: round_constant = 64'h8000000000000080;
                18: round_constant = 64'h000000000000800A;
                19: round_constant = 64'h800000008000000A;
                20: round_constant = 64'h8000000080008081;
                21: round_constant = 64'h8000000000008080;
                22: round_constant = 64'h0000000080000001;
                23: round_constant = 64'h8000000080008008;

                default:
                    round_constant = 64'h0000000000000000;

            endcase

        end
    endfunction


    // =========================================================
    // Keccak-f[1600]
    // =========================================================

    always @* begin

        // -----------------------------------------------------
        // Unpack 1600-bit state into 25 lanes
        //
        // lane = x + 5*y
        // -----------------------------------------------------

        for (y = 0; y < 5; y = y + 1) begin

            for (x = 0; x < 5; x = x + 1) begin

                A[x][y] =
                    state_in[(x + 5*y)*64 +: 64];

            end

        end


        // -----------------------------------------------------
        // 24 rounds
        // -----------------------------------------------------

        for (round = 0; round < 24; round = round + 1) begin

            // =================================================
            // THETA
            // =================================================

            for (x = 0; x < 5; x = x + 1) begin

                C[x] =
                    A[x][0] ^
                    A[x][1] ^
                    A[x][2] ^
                    A[x][3] ^
                    A[x][4];

            end


            for (x = 0; x < 5; x = x + 1) begin

                D[x] =
                    C[(x + 4) % 5] ^
                    rotl64(
                        C[(x + 1) % 5],
                        1
                    );

            end


            for (x = 0; x < 5; x = x + 1) begin

                for (y = 0; y < 5; y = y + 1) begin

                    A[x][y] =
                        A[x][y] ^ D[x];

                end

            end


            // =================================================
            // RHO + PI
            // =================================================

            for (x = 0; x < 5; x = x + 1) begin

                for (y = 0; y < 5; y = y + 1) begin

                    B[y][(2*x + 3*y) % 5] =
                        rotl64(
                            A[x][y],
                            rho_offset(x, y)
                        );

                end

            end


            // =================================================
            // CHI
            // =================================================

            for (x = 0; x < 5; x = x + 1) begin

                for (y = 0; y < 5; y = y + 1) begin

                    A[x][y] =
                        B[x][y] ^
                        ((~B[(x + 1) % 5][y]) &
                         B[(x + 2) % 5][y]);

                end

            end


            // =================================================
            // IOTA
            // =================================================

            A[0][0] =
                A[0][0] ^
                round_constant(round);

        end


        // -----------------------------------------------------
        // Pack lanes back into 1600-bit state
        // -----------------------------------------------------

        for (y = 0; y < 5; y = y + 1) begin

            for (x = 0; x < 5; x = x + 1) begin

                state_out[(x + 5*y)*64 +: 64] =
                    A[x][y];

            end

        end

    end

endmodule