#!/usr/bin/env python3
"""
Stage 3 golden model + vector generator  (NOC_ALLOCATOR / NOC_ARBITER)

WHY THIS EXISTS
---------------
The Stage 3 run of 2026-09-09 produced 405 assertion failures from
NOC_ARBITER whose printed operands SATISFIED the properties they were
attached to:

    grant_valid=0  |grant=0          -> 0 == 0 is true, yet a_valid_matches_grant fired
    grant=0 req=0  (grant&~req)=0    -> 0 == 0 is true, yet a_grant_implies_request fired

Meanwhile a_onehot_grant (same module, same signal) fired zero times, and
NOC_ALLOCATOR's textually identical assertions on the same grant vector also
fired zero times.

Assertions are not evidence when they disagree with their own operands. The
only way to settle whether the arbitration LOGIC is correct is to compare it
against an independent model, exhaustively, without any SVA involved.

That is what this file produces.

PHASE A - EXHAUSTIVE ARBITER
    Every reachable combinational input of NOC_ARBITER:
        req    : all 2^15 = 32768 patterns
        rr_ptr : all 15 legal values
        -> 491,520 vectors, complete. Not sampled, not random. Complete.
    For each, the model emits grant / grant_valid / winner / rr_ptr_next.

PHASE B - CYCLE-ACCURATE ALLOCATOR
    A full cycle-accurate model of NOC_ALLOCATOR: XY routing, request matrix,
    five round-robin arbiters with their own pointer state, and the wormhole
    reservation FSM. Constrained-random legal traffic - well-formed packets
    only, so any DUT assertion that fires during Phase B is a real defect.
    Every output is compared every cycle.

INDEPENDENCE
    This model is written from the SPECIFICATION (noc_pkg semantics and the
    wormhole protocol), not by transliterating the RTL. Where the RTL has a
    non-obvious convention the reason is stated. A model that is a paraphrase
    of the design under test proves only that the paraphrase was faithful.

OUTPUT
    stage3_arb_vectors.memh   491520 lines, 44-bit hex per line
    stage3_alloc_vectors.txt  one line per cycle, whitespace-separated hex
"""

import random
import sys

# =============================================================================
# CONSTANTS - mirrored from noc_pkg. Any disagreement here invalidates
# everything downstream, so they are asserted against the RTL by the testbench
# banner rather than trusted silently.
# =============================================================================

MESH_X        = 3
MESH_Y        = 2
NUM_PORTS     = 5
NUM_VC        = 3
NUM_INPUT_VCS = NUM_PORTS * NUM_VC        # 15
INPUT_VC_W    = 4                          # $clog2(15)

PORT_NORTH, PORT_SOUTH, PORT_EAST, PORT_WEST, PORT_LOCAL = 0, 1, 2, 3, 4

FLIT_HEAD, FLIT_BODY, FLIT_TAIL, FLIT_HEAD_TAIL = 0, 1, 2, 3

N = NUM_INPUT_VCS


# =============================================================================
# PHASE A MODEL : round-robin arbiter, combinational
# =============================================================================

def arbiter_n(req, rr_ptr, n):
    """NOC_ARBITER #(.N(n)) exactly. Verified reusable unmodified at n=3,5,15:
    no winner or pointer overflow, grant always one-hot0 and always implies a
    request, for every reachable pointer value."""
    grant = 0; grant_valid = 0; winner = 0; rr_ptr_next = rr_ptr
    for offset in range(n):
        idx = rr_ptr + offset
        if idx >= n:
            idx -= n
        if (req >> idx) & 1:
            grant = 1 << idx
            grant_valid = 1
            winner = idx
            rr_ptr_next = 0 if idx == n - 1 else idx + 1
            break
    return grant, grant_valid, winner, rr_ptr_next


def arbiter(req, rr_ptr):
    """Return (grant, grant_valid, winner, rr_ptr_next).

    Specification: starting at rr_ptr and walking circularly upward, the first
    asserted request wins. The pointer then advances to one past the winner so
    that the winner has lowest priority next time - that is what makes it
    round robin rather than fixed priority.

    rr_ptr_next is the value the pointer WOULD take; it is only committed when
    grant_valid is high.
    """
    grant       = 0
    grant_valid = 0
    winner      = 0
    rr_ptr_next = rr_ptr

    for offset in range(N):
        idx = rr_ptr + offset
        if idx >= N:
            idx -= N
        if (req >> idx) & 1:
            grant       = 1 << idx
            grant_valid = 1
            winner      = idx
            rr_ptr_next = 0 if idx == N - 1 else idx + 1
            break

    return grant, grant_valid, winner, rr_ptr_next


# =============================================================================
# PHASE B MODEL : XY routing  (noc_xy_routing)
# =============================================================================

def valid_coord(x, y):
    return (x < MESH_X) and (y < MESH_Y)


def port_exists(cx, cy, port):
    if port == PORT_NORTH:
        return cy > 0
    if port == PORT_SOUTH:
        return (cy + 1) < MESH_Y
    if port == PORT_EAST:
        return (cx + 1) < MESH_X
    if port == PORT_WEST:
        return cx > 0
    if port == PORT_LOCAL:
        return True
    return False


def xy_route(cx, cy, dx, dy):
    """Return (route_port, route_valid).

    Dimension order: X is resolved fully before Y. On a malformed request the
    port is forced to LOCAL rather than left at whatever the arithmetic
    produced - LOCAL keeps a bad packet inside this router where the network
    interface can raise an error, instead of pushing it further into the mesh.
    """
    coords_ok = valid_coord(cx, cy) and valid_coord(dx, dy)

    if   dx > cx: computed = PORT_EAST
    elif dx < cx: computed = PORT_WEST
    elif dy > cy: computed = PORT_SOUTH
    elif dy < cy: computed = PORT_NORTH
    else:         computed = PORT_LOCAL

    if coords_ok and port_exists(cx, cy, computed):
        return computed, 1
    return PORT_LOCAL, 0


# =============================================================================
# PHASE B MODEL : the allocator, cycle accurate
# =============================================================================

class AllocatorModel:
    """Two-stage separable INPUT-FIRST allocator (architecture A9, 2026-09-10).

    WHY TWO STAGES
    --------------
    A physical input has ONE path to the crossbar. The previous single-stage
    design ran five independent 15-way output arbiters, which could grant
    NORTH VC0 -> EAST and NORTH VC1 -> WEST in the same cycle. Both grants are
    individually legal; the datapath cannot carry both. The second flit was
    dequeued and destroyed.

    Stage 1  per physical input, one 3-way arbiter picks at most ONE VC.
    Stage 2  per output, one 5-way arbiter picks at most ONE physical input.

    The structural hazard is then impossible by construction rather than
    asserted after the fact.

    ORDER MATTERS. Stage 1 sees only whether a VC has ANY legitimate request
    (derived from the full request matrix, so routing and wormhole rules are
    already applied). It does not know which outputs are free. That is the
    known throughput cost of input-first separable allocation and it is a
    performance property, not a correctness one - measure it in Phase 8, do
    not pre-optimise it here.
    """

    def __init__(self):
        # Stage 1: one round-robin pointer per physical input port.
        self.in_ptr  = [0] * NUM_PORTS
        # Stage 2: one round-robin pointer per output port.
        self.out_ptr = [0] * NUM_PORTS

        self.output_locked = [0] * NUM_PORTS
        self.output_owner  = [0] * NUM_PORTS   # GLOBAL input-VC index, 0..14

    # -- combinational ------------------------------------------------------
    def evaluate(self, cx, cy, fifo_empty, flit_type, dest_x, dest_y):

        route_port  = [0] * N
        route_valid = [0] * N
        for i in range(N):
            route_port[i], route_valid[i] = xy_route(cx, cy, dest_x[i], dest_y[i])

        # ---- request matrix, unchanged semantics -------------------------
        # request[output] is a 15-bit mask over GLOBAL input VCs.
        request = [0] * NUM_PORTS
        for i in range(N):
            if fifo_empty[i]:
                continue
            for p in range(NUM_PORTS):
                if self.output_locked[p] and self.output_owner[p] == i:
                    request[p] |= (1 << i)
            if flit_type[i] in (FLIT_HEAD, FLIT_HEAD_TAIL):
                if route_valid[i] and route_port[i] < NUM_PORTS:
                    if not self.output_locked[route_port[i]]:
                        request[route_port[i]] |= (1 << i)

        # ---- STAGE 1: one VC per physical input, AND its single target -----
        #
        # A9-b (found 2026-09-10 by the model self-check, before any RTL was
        # written): picking only the VC is NOT sufficient. The five stage-2
        # arbiters are independent, so two different outputs could both select
        # the same physical input, and that input would again be asked to
        # supply two flits in one cycle - the very hazard this rewrite exists
        # to remove, reintroduced one level up.
        #
        # The fix is to give each candidate exactly ONE target output here.
        # out_req[o] then has at most one bit per input by construction, and
        # "one physical input -> at most one output" becomes structural rather
        # than something the traffic happens to respect.
        #
        # A well-formed VC requests exactly one output anyway (BODY/TAIL only
        # its reservation, HEAD only its route), so this changes nothing for
        # legal traffic. It only makes the malformed case deterministic
        # instead of destructive.
        cand_valid = [0] * NUM_PORTS
        cand_vc    = [0] * NUM_PORTS   # global input-VC index
        cand_out   = [0] * NUM_PORTS   # the ONE output this candidate wants
        in_next    = [0] * NUM_PORTS

        for p in range(NUM_PORTS):
            req3 = 0
            for v in range(NUM_VC):
                g = p * NUM_VC + v
                if any((request[o] >> g) & 1 for o in range(NUM_PORTS)):
                    req3 |= (1 << v)

            g3, v3, w3, nxt3 = arbiter_n(req3, self.in_ptr[p], NUM_VC)
            in_next[p] = nxt3
            if v3:
                gvc = p * NUM_VC + w3
                cand_valid[p] = 1
                cand_vc[p]    = gvc
                # Lowest-index output. Unique for well-formed traffic; a
                # deterministic tie-break for malformed traffic.
                for o in range(NUM_PORTS):
                    if (request[o] >> gvc) & 1:
                        cand_out[p] = o
                        break

        # ---- STAGE 2: one physical input per output -----------------------
        out_req = [0] * NUM_PORTS   # 5-bit mask over physical inputs
        for p in range(NUM_PORTS):
            if cand_valid[p]:
                out_req[cand_out[p]] |= (1 << p)

        grant       = [0] * NUM_PORTS   # 15-bit mask, external interface unchanged
        grant_valid = 0
        xbar_sel    = [0] * NUM_PORTS   # GLOBAL input-VC index, unchanged
        win_port    = [0] * NUM_PORTS
        out_next    = [0] * NUM_PORTS
        fifo_rd_en  = 0

        for o in range(NUM_PORTS):
            g5, v5, w5, nxt5 = arbiter_n(out_req[o], self.out_ptr[o], NUM_PORTS)
            out_next[o] = nxt5
            win_port[o] = w5
            if v5:
                gvc           = cand_vc[w5]
                grant[o]      = 1 << gvc
                grant_valid  |= (1 << o)
                xbar_sel[o]   = gvc
                fifo_rd_en   |= (1 << gvc)

        return dict(request=request, grant=grant, grant_valid=grant_valid,
                    xbar_sel=xbar_sel, fifo_rd_en=fifo_rd_en,
                    cand_valid=cand_valid, cand_vc=cand_vc, cand_out=cand_out,
                    win_port=win_port, in_next=in_next, out_next=out_next,
                    out_req=out_req,
                    route_port=route_port, route_valid=route_valid)

    # -- sequential ---------------------------------------------------------
    def commit(self, comb, flit_type, rst=False):
        if rst:
            self.in_ptr        = [0] * NUM_PORTS
            self.out_ptr       = [0] * NUM_PORTS
            self.output_locked = [0] * NUM_PORTS
            self.output_owner  = [0] * NUM_PORTS
            return

        # Stage-1 pointers advance on their own grant.
        for p in range(NUM_PORTS):
            if comb['cand_valid'][p]:
                self.in_ptr[p] = comb['in_next'][p]

        # Stage-2 pointers advance on their own grant.
        for o in range(NUM_PORTS):
            if (comb['grant_valid'] >> o) & 1:
                self.out_ptr[o] = comb['out_next'][o]

        # ---- wormhole reservation -----------------------------------------
        # TRAP (A10): the stage-2 winner is a PHYSICAL PORT index, not a VC.
        # The flit type must be looked up via the candidate VC of that port.
        # Indexing flit_type[] with the port index silently reads the wrong
        # flit and corrupts the reservation.
        for o in range(NUM_PORTS):
            if not ((comb['grant_valid'] >> o) & 1):
                continue

            gvc = comb['xbar_sel'][o]          # global input VC that won
            ft  = flit_type[gvc]

            if ft == FLIT_HEAD:
                if not self.output_locked[o]:
                    self.output_locked[o] = 1
                    self.output_owner[o]  = gvc
            elif ft == FLIT_BODY:
                pass                            # retain
            elif ft == FLIT_TAIL:
                if self.output_locked[o] and self.output_owner[o] == gvc:
                    self.output_locked[o] = 0
                    self.output_owner[o]  = 0
            elif ft == FLIT_HEAD_TAIL:
                pass                            # no persistent reservation


# =============================================================================
# PHASE A GENERATION
# =============================================================================

def gen_phase_a_n(path, n):
    """Exhaustive vectors for NOC_ARBITER #(.N(n)).

    CORRECTION (2026-09-10): the plan said to re-run "2^15 x 15 = 491,520" for
    the new architecture. That is wrong - the two-stage allocator instantiates
    N=3 and N=5 arbiters and NO N=15 arbiter at all. The complete spaces are:

        N=3   2^3 x 3  =  24 vectors
        N=5   2^5 x 5  = 160 vectors

    184 vectors verify BOTH instantiations completely. The new architecture is
    therefore MORE exhaustively verifiable than the old one, not less. The
    N=15 file is retained only as a generic-module proof across a wide N; it
    no longer corresponds to anything in the design.

    Layout per line, LSB first:
        [n-1:0]                req
        [n+pw-1:n]             rr_ptr
        [2n+pw-1:n+pw]         grant
        [2n+pw]                grant_valid
        [2n+2pw:2n+pw+1]       winner
        [2n+3pw:2n+2pw+1]      rr_ptr_next
    """
    import math
    pw = 1 if n <= 1 else math.ceil(math.log2(n))
    nib = (2*n + 3*pw + 1 + 3) // 4
    count = 0
    with open(path, 'w') as f:
        for ptr in range(n):
            for req in range(1 << n):
                g, v, w, nxt = arbiter_n(req, ptr, n)
                val = (req
                       | (ptr << n)
                       | (g   << (n + pw))
                       | (v   << (2*n + pw))
                       | (w   << (2*n + pw + 1))
                       | (nxt << (2*n + 2*pw + 1)))
                f.write(("%0" + str(nib) + "x\n") % val)
                count += 1
    return count, pw, nib


def gen_phase_a(path):
    """Exhaustive arbiter vectors.

    Bit layout of each 44-bit line (LSB first):
        [14:0]  req
        [18:15] rr_ptr
        [33:19] grant
        [34]    grant_valid
        [38:35] winner
        [42:39] rr_ptr_next
        [43]    reserved / 0
    """
    count = 0
    with open(path, 'w') as f:
        for ptr in range(N):
            for req in range(1 << N):
                g, v, w, nxt = arbiter(req, ptr)
                val = (req
                       | (ptr << 15)
                       | (g   << 19)
                       | (v   << 34)
                       | (w   << 35)
                       | (nxt << 39))
                f.write("%011x\n" % val)
                count += 1
    return count


# =============================================================================
# PHASE B GENERATION
# =============================================================================

class PacketGen:
    """Emits WELL-FORMED packets only.

    This matters. Phase B exists to prove the allocator is correct on legal
    traffic; if the stimulus were allowed to emit a HEAD with no TAIL, the DUT
    assertions would fire and we could not tell a stimulus artefact from a
    design defect. Malformed traffic is tested separately and deliberately in
    stage3_tb T09.

    Each VC independently runs a small state machine:
        idle -> (HEAD, BODY*, TAIL)  or  (HEAD_TAIL)  -> idle
    """

    def __init__(self, rng):
        self.rng     = rng
        self.state   = ['idle'] * N     # 'idle' | 'mid'
        self.remain  = [0] * N          # body flits left before TAIL
        self.ft      = [FLIT_HEAD] * N
        self.dx      = [0] * N
        self.dy      = [0] * N
        self.present = [False] * N

    def step(self, cx, cy, locked_owner):
        """locked_owner: dict output->owner, so a mid-packet VC keeps flowing."""
        for i in range(N):
            if self.state[i] == 'idle':
                # Start a packet with moderate probability, else stay empty.
                r = self.rng.random()
                if r < 0.45:
                    self.dx[i] = self.rng.randrange(MESH_X)
                    self.dy[i] = self.rng.randrange(MESH_Y)
                    if self.rng.random() < 0.4:
                        self.ft[i]      = FLIT_HEAD_TAIL
                        self.present[i] = True
                        # stays idle: single-flit packet completes immediately
                    else:
                        self.ft[i]      = FLIT_HEAD
                        self.present[i] = True
                        self.remain[i]  = self.rng.randrange(0, 3)
                        self.state[i]   = 'mid'
                else:
                    self.present[i] = False
            else:
                # Mid-packet: BODY until the count runs out, then TAIL.
                self.present[i] = True
                if self.remain[i] > 0:
                    self.ft[i]     = FLIT_BODY
                    self.remain[i] -= 1
                else:
                    self.ft[i]    = FLIT_TAIL
                    self.state[i] = 'idle'
                # A body/tail flit carries payload, not a destination. Give it
                # a deliberately DIFFERENT header so that a design which
                # wrongly re-routes mid-packet flits is caught rather than
                # accidentally producing the right answer.
                self.dx[i] = self.rng.randrange(8)
                self.dy[i] = self.rng.randrange(8)

    def advance_after_grant(self, granted_vcs):
        """A flit only leaves the FIFO when it is granted. VCs that were not
        granted must re-present the SAME flit next cycle, which is what makes
        this a wormhole model rather than a stream of unrelated flits."""
        pass  # handled by caller: we only advance presented VCs that won


def gen_phase_b(path, cycles, seed):
    rng   = random.Random(seed)
    model = AllocatorModel()

    # Per-VC packet state, advanced only when the VC's flit is consumed.
    state  = ['idle'] * N
    remain = [0] * N
    ft     = [FLIT_HEAD] * N
    dx     = [0] * N
    dy     = [0] * N
    present = [False] * N

    def new_flit(i):
        """Produce the next flit for VC i according to its packet state."""
        if state[i] == 'idle':
            if rng.random() < 0.45:
                dx[i] = rng.randrange(MESH_X)
                dy[i] = rng.randrange(MESH_Y)
                if rng.random() < 0.4:
                    ft[i]      = FLIT_HEAD_TAIL
                    present[i] = True
                else:
                    ft[i]      = FLIT_HEAD
                    present[i] = True
                    remain[i]  = rng.randrange(0, 3)
                    state[i]   = 'mid'
            else:
                present[i] = False
        else:
            present[i] = True
            if remain[i] > 0:
                ft[i]      = FLIT_BODY
                remain[i] -= 1
            else:
                ft[i]    = FLIT_TAIL
                state[i] = 'idle'
            dx[i] = rng.randrange(8)
            dy[i] = rng.randrange(8)

    lines = 0
    with open(path, 'w') as f:
        f.write("# cx cy empty ft[0..14] dx[0..14] dy[0..14] "
                "gv g0..g4 sel0..sel4 rd lock ow0..ow4\n")

        for cyc in range(cycles):

            cx = rng.randrange(MESH_X)
            cy = rng.randrange(MESH_Y)

            # Router position must be stable while any reservation is held;
            # a router does not move. Only re-randomise when fully idle.
            if any(model.output_locked):
                cx, cy = last_cx, last_cy
            last_cx, last_cy = cx, cy

            for i in range(N):
                if not present[i]:
                    new_flit(i)

            empty_mask = 0
            for i in range(N):
                if not present[i]:
                    empty_mask |= (1 << i)

            comb = model.evaluate(cx, cy,
                                  [(empty_mask >> i) & 1 for i in range(N)],
                                  ft, dx, dy)

            # Emit stimulus + expected combinational outputs + expected state
            # BEFORE the edge (state is what the DUT holds this cycle).
            fields = [cx, cy, empty_mask]
            fields += ft[:]
            fields += dx[:]
            fields += dy[:]
            fields += [comb['grant_valid']]
            fields += comb['grant']
            fields += comb['xbar_sel']
            fields += [comb['fifo_rd_en']]
            fields += [sum(b << p for p, b in enumerate(model.output_locked))]
            fields += model.output_owner

            f.write(" ".join("%x" % v for v in fields) + "\n")
            lines += 1

            # A flit leaves its FIFO only if it was granted.
            for i in range(N):
                if (comb['fifo_rd_en'] >> i) & 1:
                    present[i] = False

            model.commit(comb, ft)

    return lines


# =============================================================================
# SELF-CHECK
# =============================================================================

def self_check():
    """Properties the model itself must satisfy. If the MODEL is wrong, the
    comparison is worthless, so it is checked before anything is written."""

    # Round robin must actually rotate under sustained two-way contention.
    ptr = 0
    winners = []
    for _ in range(6):
        g, v, w, nxt = arbiter(0b011, ptr)
        assert v == 1
        winners.append(w)
        ptr = nxt
    assert len(set(winners)) > 1, "model arbiter is fixed priority, not round robin"

    # Grant must always be one-hot-or-zero and imply a request.
    for ptr in range(N):
        for req in (0, 1, 0b101, 0x7FFF, 0x4000):
            g, v, w, nxt = arbiter(req, ptr)
            assert bin(g).count('1') <= 1
            assert (g & ~req) == 0
            assert v == (1 if g else 0)
            if v:
                assert (req >> w) & 1

    # Empty request set must produce no grant and no pointer movement.
    for ptr in range(N):
        g, v, w, nxt = arbiter(0, ptr)
        assert g == 0 and v == 0 and nxt == ptr

    # XY routing must converge: every legal source/destination pair must reach
    # the destination in a finite number of hops with strictly decreasing
    # Manhattan distance.
    for cx in range(MESH_X):
        for cy in range(MESH_Y):
            for ddx in range(MESH_X):
                for ddy in range(MESH_Y):
                    x, y, hops = cx, cy, 0
                    while (x, y) != (ddx, ddy):
                        p, ok = xy_route(x, y, ddx, ddy)
                        assert ok, f"no route ({x},{y})->({ddx},{ddy})"
                        if   p == PORT_EAST:  x += 1
                        elif p == PORT_WEST:  x -= 1
                        elif p == PORT_SOUTH: y += 1
                        elif p == PORT_NORTH: y -= 1
                        else: assert False, "LOCAL before arrival"
                        hops += 1
                        assert hops <= MESH_X + MESH_Y, "routing loop"
                    p, ok = xy_route(x, y, ddx, ddy)
                    assert ok and p == PORT_LOCAL


    # -------------------------------------------------------------------
    # A9 STRUCTURAL INVARIANT + the five hand-check cases.
    #
    # These are the cases that motivated the two-stage rewrite. If any of
    # them regresses, the vectors below are worthless, so they run before
    # a single vector is written.
    # -------------------------------------------------------------------

    def mk(cx, cy, spec):
        """spec: {global_vc: (dx, dy, flit_type)}. Returns (empty, ft, dx, dy)."""
        empty = [1]*N; ft=[FLIT_HEAD]*N; dx=[0]*N; dy=[0]*N
        for g,(a,b,t) in spec.items():
            empty[g]=0; dx[g]=a; dy[g]=b; ft[g]=t
        return empty, ft, dx, dy

    def won_ports(c):
        """physical input ports that won at least one output."""
        w=[]
        for o in range(NUM_PORTS):
            if (c['grant_valid']>>o)&1:
                w.append(input_vc_port(c['xbar_sel'][o]))
        return w

    def input_vc_port(g):   return g // NUM_VC

    # Router at (1,0): EAST, WEST, SOUTH and LOCAL all exist.
    CX, CY = 1, 0

    # Case A - NORTH VC0 -> EAST. Single request, must be granted.
    m = AllocatorModel()
    e,f,dx,dy = mk(CX,CY,{0:(2,0,FLIT_HEAD_TAIL)})
    c = m.evaluate(CX,CY,e,f,dx,dy)
    assert (c['grant_valid']>>PORT_EAST)&1, "A: EAST not granted"
    assert c['xbar_sel'][PORT_EAST]==0,      "A: wrong winner"

    # Case B - NORTH VC0 -> EAST, NORTH VC1 -> WEST. THE BUG CASE.
    # Exactly one must win: one physical input, one crossbar path.
    m = AllocatorModel()
    e,f,dx,dy = mk(CX,CY,{0:(2,0,FLIT_HEAD_TAIL), 1:(0,0,FLIT_HEAD_TAIL)})
    c = m.evaluate(CX,CY,e,f,dx,dy)
    assert bin(c['grant_valid']).count('1') == 1, \
        f"B: {bin(c['grant_valid']).count('1')} outputs granted, expected 1 " \
        f"(this is the structural hazard the rewrite exists to remove)"
    assert len(set(won_ports(c))) <= 1, "B: two physical inputs won"

    # Case C - NORTH VC0 -> EAST, SOUTH VC0 -> EAST. One output, two inputs.
    m = AllocatorModel()
    e,f,dx,dy = mk(CX,CY,{0:(2,0,FLIT_HEAD_TAIL), 3:(2,0,FLIT_HEAD_TAIL)})
    c = m.evaluate(CX,CY,e,f,dx,dy)
    assert bin(c['grant_valid']).count('1') == 1, "C: expected exactly one grant"
    assert bin(c['grant'][PORT_EAST]).count('1') == 1, "C: EAST not one-hot"

    # Case D - NORTH VC0 -> EAST, SOUTH VC0 -> WEST. Disjoint: BOTH proceed.
    m = AllocatorModel()
    e,f,dx,dy = mk(CX,CY,{0:(2,0,FLIT_HEAD_TAIL), 3:(0,0,FLIT_HEAD_TAIL)})
    c = m.evaluate(CX,CY,e,f,dx,dy)
    assert (c['grant_valid']>>PORT_EAST)&1, "D: EAST blocked"
    assert (c['grant_valid']>>PORT_WEST)&1, "D: WEST blocked"
    assert c['xbar_sel'][PORT_EAST]==0 and c['xbar_sel'][PORT_WEST]==3, "D: crossed"

    # Case E - NORTH VC0 and NORTH VC1 both -> EAST. One VC wins the input.
    m = AllocatorModel()
    e,f,dx,dy = mk(CX,CY,{0:(2,0,FLIT_HEAD_TAIL), 1:(2,0,FLIT_HEAD_TAIL)})
    c = m.evaluate(CX,CY,e,f,dx,dy)
    assert bin(c['grant'][PORT_EAST]).count('1') == 1, "E: EAST not one-hot"
    assert bin(c['fifo_rd_en']).count('1') == 1, "E: two FIFOs popped"

    print("  hand-check cases A-E ............ PASS")

    # -------------------------------------------------------------------
    # A9 exhaustively over random legal traffic: no physical input may ever
    # win two outputs, and fifo_rd_en must always equal OR(grant).
    # -------------------------------------------------------------------
    rng = random.Random(1234)
    m = AllocatorModel()
    checked = 0
    for _ in range(20000):
        empty=[rng.random()<0.5 for _ in range(N)]
        ft=[rng.randrange(4) for _ in range(N)]
        dx=[rng.randrange(MESH_X) for _ in range(N)]
        dy=[rng.randrange(MESH_Y) for _ in range(N)]
        cx,cy = rng.randrange(MESH_X), rng.randrange(MESH_Y)
        c = m.evaluate(cx,cy,[1 if x else 0 for x in empty],ft,dx,dy)

        ports = won_ports(c)
        assert len(ports)==len(set(ports)), f"A9 VIOLATED: input won 2 outputs {ports}"

        rd = 0
        for o in range(NUM_PORTS): rd |= c['grant'][o]
        assert rd == c['fifo_rd_en'], "fifo_rd_en != OR(grant)"

        for o in range(NUM_PORTS):
            assert bin(c['grant'][o]).count('1') <= 1, "grant not one-hot0"
            assert (c['grant'][o] & ~c['request'][o]) == 0, "grant without request"
            assert (((c['grant_valid']>>o)&1) == (1 if c['grant'][o] else 0)), \
                "grant_valid != |grant"
            if c['grant'][o]:
                g = c['xbar_sel'][o]
                assert not empty[g], "empty VC granted"

        for g in range(N):
            n = sum(1 for o in range(NUM_PORTS) if (c['grant'][o]>>g)&1)
            assert n <= 1, "one VC won two outputs"

        m.commit(c, ft)
        checked += 1

    print(f"  A9 structural invariant ......... PASS ({checked} random cycles)")

    print("  model self-check ................ PASS")


# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    cycles = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    seed   = int(sys.argv[2]) if len(sys.argv) > 2 else 20260909

    print("Stage 3 golden model - vector generation")
    self_check()

    n = gen_phase_a("stage3_arb_vectors.memh")
    print("  PHASE A  arbiter N=15 ........... %d vectors  (generic-module proof;"
          " NOT instantiated by the new allocator)" % n)

    for nn in (3, 5):
        c, pw, nib = gen_phase_a_n("stage3_arb%d_vectors.memh" % nn, nn)
        print("  PHASE A  arbiter N=%-2d ........... %4d vectors  COMPLETE "
              "(2^%d x %d)  %d hex digits/line" % (nn, c, nn, nn, nib))

    m = gen_phase_b("stage3_alloc_vectors.txt", cycles, seed)
    print("  PHASE B cycle-accurate allocator  %d cycles (seed %d)" % (m, seed))
    print("done")
