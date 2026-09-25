//=============================================================================
// Module 2: NoC FIFO
// File: noc_fifo.sv
//
// Purpose:
//     Per-port / per-VC flit buffer for the NoC router.
//
// Responsibilities:
//     - Store incoming flits
//     - Preserve FIFO ordering
//     - Provide the oldest flit at the output
//     - Track occupancy and free slots
//     - Indicate empty/full status
//     - Support simultaneous read and write
//     - Emit a credit pulse when a slot is freed
//     - Report an overflow attempt loudly rather than silently
//
// Does NOT handle:
//     - Routing, arbitration, crossbar switching, VC allocation
//     - Packet generation
//     - Credit accounting (the counters live in noc_credit_control)
//
// REVISION: Review 01 repairs applied
//   F1 / L-04  Assertion added on (wr_en && full). A dropped flit is now
//              loud instead of silent.
//   F2 / L-12  ram_style = "distributed" forced on the storage array.
//   F3 / L-10  Reset stays SYNCHRONOUS. Confirmed against AMD guidance:
//              synchronous reset gives better mapping flexibility and lower
//              control-set pressure, and asynchronous reset degrades
//              LUTRAM/SRL inference. BRIEF HC6 is corrected, not this file.
//   F4         disable iff (rst) added to every assertion.
//   F5         credit_valid pulse output added, registered.
//   F6         Elaboration guard on DEPTH.
//   L-05       flit_t no longer carries a valid bit.
//=============================================================================

`timescale 1ns/1ps
module noc_fifo #(
    parameter int unsigned DEPTH = noc_pkg::FIFO_DEPTH
) (
    input  logic           clk,
    input  logic           rst,

    //-------------------------------------------------------------------------
    // Write interface
    //-------------------------------------------------------------------------

    input  noc_pkg::flit_t wr_flit,
    input  logic           wr_en,

    //-------------------------------------------------------------------------
    // Read interface
    //-------------------------------------------------------------------------

    input  logic           rd_en,

    //-------------------------------------------------------------------------
    // FIFO output
    //
    // The oldest flit is continuously visible here. rd_en is required only
    // to REMOVE it, not to observe it.
    //-------------------------------------------------------------------------

    output noc_pkg::flit_t rd_flit,

    //-------------------------------------------------------------------------
    // FIFO status
    //-------------------------------------------------------------------------

    output logic empty,
    output logic full,

    //-------------------------------------------------------------------------
    // Occupancy and free-slot counts
    //-------------------------------------------------------------------------

    output logic [$clog2(DEPTH + 1)-1:0] occupancy,
    output logic [$clog2(DEPTH + 1)-1:0] free_slots,

    //-------------------------------------------------------------------------
    // Credit pulse
    //
    // One cycle high, one clock after a flit is successfully dequeued and a
    // buffer slot therefore becomes available.
    //
    // Registered deliberately. free_slots is a LEVEL, and a level cannot
    // increment an upstream counter without a race. The credit protocol
    // needs an EVENT. Registering it also keeps rd_en out of the upstream
    // combinational path.
    //-------------------------------------------------------------------------

    output logic credit_valid
);

    import noc_pkg::*;

    //-------------------------------------------------------------------------
    // Elaboration-time check
    //-------------------------------------------------------------------------

    initial begin
        if (DEPTH < 2)
            $fatal(1, "noc_fifo: DEPTH must be at least 2, got %0d", DEPTH);
    end

    //-------------------------------------------------------------------------
    // Derived widths
    //-------------------------------------------------------------------------

    localparam int unsigned PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam int unsigned OCC_WIDTH = $clog2(DEPTH + 1);


    //-------------------------------------------------------------------------
    // FIFO storage
    //
    // Each entry stores a complete flit: flit_data, flit_type, vc_id.
    //
    // ram_style = "distributed" is MANDATORY, not advisory. Without it
    // Vivado may map this array to flip-flops plus an explicit read mux,
    // which roughly doubles the LUT cost of the largest block in the NoC.
    // It must never map to BRAM: BRAM has a registered read port and this
    // FIFO presents its head combinationally.
    //-------------------------------------------------------------------------

    (* ram_style = "distributed" *)
    flit_t fifo_mem [0:DEPTH-1];


    //-------------------------------------------------------------------------
    // Read/write pointers and occupancy counter
    //-------------------------------------------------------------------------

    logic [PTR_WIDTH-1:0] wr_ptr;
    logic [PTR_WIDTH-1:0] rd_ptr;
    logic [OCC_WIDTH-1:0] count;


    //-------------------------------------------------------------------------
    // Qualified read and write strobes
    //
    // Computed once and used everywhere, so the pointers and the occupancy
    // counter can never disagree about whether a transfer happened.
    //-------------------------------------------------------------------------

    logic do_write;
    logic do_read;

    assign do_write = wr_en && !full;
    assign do_read  = rd_en && !empty;


    //-------------------------------------------------------------------------
    // Status signals + head flit
    //
    // Keep all combinational FIFO-visible state in one process so the
    // status and head are described together. The FIFO protocol still
    // treats count as the source of truth for empty/full.
    //-------------------------------------------------------------------------

    always_comb begin

        empty      = (count == '0);
        full       = (count == OCC_WIDTH'(DEPTH));
        occupancy  = count;
        free_slots = OCC_WIDTH'(DEPTH) - count;

        if (count != '0)
            rd_flit = fifo_mem[rd_ptr];
        else
            rd_flit = '0;

    end


    //-------------------------------------------------------------------------
    // FIFO sequential logic
    //
    // Synchronous reset throughout. The storage array is deliberately NOT
    // reset: resetting it would force it out of LUTRAM into flip-flops, and
    // its contents are meaningless while count is zero anyway.
    //-------------------------------------------------------------------------

    always_ff @(posedge clk) begin

        if (rst) begin

            wr_ptr       <= '0;
            rd_ptr       <= '0;
            count        <= '0;
            credit_valid <= 1'b0;

        end
        else begin

            //-----------------------------------------------------------------
            // WRITE
            //-----------------------------------------------------------------

            if (do_write) begin

                fifo_mem[wr_ptr] <= wr_flit;

                if (wr_ptr == PTR_WIDTH'(DEPTH - 1))
                    wr_ptr <= '0;
                else
                    wr_ptr <= wr_ptr + 1'b1;

            end

            //-----------------------------------------------------------------
            // READ
            //-----------------------------------------------------------------

            if (do_read) begin

                if (rd_ptr == PTR_WIDTH'(DEPTH - 1))
                    rd_ptr <= '0;
                else
                    rd_ptr <= rd_ptr + 1'b1;

            end

            //-----------------------------------------------------------------
            // OCCUPANCY UPDATE
            //
            //   write only  -> +1
            //   read only   -> -1
            //   both        -> unchanged
            //   neither     -> unchanged
            //-----------------------------------------------------------------

            unique case ({do_write, do_read})

                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                2'b11:   count <= count;
                default: count <= count;

            endcase

            //-----------------------------------------------------------------
            // CREDIT PULSE
            //-----------------------------------------------------------------

            credit_valid <= do_read;

        end

    end


    //=========================================================================
    // ASSERTIONS
    //
    // Simulation only. Vivado ignores concurrent assertions during
    // synthesis. Every one carries disable iff (rst) so that none can fire
    // on X values before the first clock edge -- a checker that cries wolf
    // at time zero is a checker that gets ignored.
    //=========================================================================

    // ------------------------------------------------------------------------
    // OVERFLOW ATTEMPT.  (F1 / L-04)
    //
    // The FIFO refuses a write when full, which prevents corruption but
    // DISCARDS THE FLIT. In a network a silently discarded flit presents as
    // a packet that vanished, and it gets hunted in the routing logic.
    //
    // Until noc_credit_control exists there is no backpressure and this WILL
    // fire under load. That is the intended behaviour: it makes the missing
    // flow control visible instead of letting it masquerade as working.
    // ------------------------------------------------------------------------

    property p_no_overflow_attempt;
        @(posedge clk) disable iff (rst)
        !(wr_en && full);
    endproperty

    a_no_overflow_attempt: assert property (p_no_overflow_attempt)
        else $error("noc_fifo: FLIT DROPPED - write attempted while full. Credit flow control is missing or broken.");


    // ------------------------------------------------------------------------
    // UNDERFLOW ATTEMPT
    // ------------------------------------------------------------------------

    property p_no_underflow_attempt;
        @(posedge clk) disable iff (rst)
        !(rd_en && empty);
    endproperty

    a_no_underflow_attempt: assert property (p_no_underflow_attempt)
        else $error("noc_fifo: read attempted while empty");


    // ------------------------------------------------------------------------
    // Occupancy must stay within range.
    // ------------------------------------------------------------------------

    property p_occupancy_in_range;
        @(posedge clk) disable iff (rst)
        (count <= OCC_WIDTH'(DEPTH));
    endproperty

    a_occupancy_in_range: assert property (p_occupancy_in_range)
        else $error("noc_fifo: occupancy exceeded configured depth");


    // ------------------------------------------------------------------------
    // Pointers must stay inside the array.
    // ------------------------------------------------------------------------

    property p_write_pointer_in_range;
        @(posedge clk) disable iff (rst)
        (wr_ptr < PTR_WIDTH'(DEPTH));
    endproperty

    a_write_pointer_in_range: assert property (p_write_pointer_in_range)
        else $error("noc_fifo: write pointer out of range");


    property p_read_pointer_in_range;
        @(posedge clk) disable iff (rst)
        (rd_ptr < PTR_WIDTH'(DEPTH));
    endproperty

    a_read_pointer_in_range: assert property (p_read_pointer_in_range)
        else $error("noc_fifo: read pointer out of range");


    // ------------------------------------------------------------------------
    // The two counters must remain consistent with each other.
    // ------------------------------------------------------------------------

    property p_counts_consistent;
        @(posedge clk) disable iff (rst)
        ((occupancy + free_slots) == OCC_WIDTH'(DEPTH));
    endproperty

    a_counts_consistent: assert property (p_counts_consistent)
        else $error("noc_fifo: occupancy and free_slots disagree");


    // ------------------------------------------------------------------------
    // A credit pulse must always correspond to a real dequeue.
    // ------------------------------------------------------------------------

    property p_credit_follows_read;
        @(posedge clk) disable iff (rst)
        credit_valid |-> $past(do_read);
    endproperty

    a_credit_follows_read: assert property (p_credit_follows_read)
        else $error("noc_fifo: credit pulse without a corresponding dequeue");

endmodule