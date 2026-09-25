#!/usr/bin/env python3
"""
Regenerate the Stage 7 (pq_attestation_tag) golden vectors V01-V08 from the
independent reference model and confirm they match the literals currently in
NOC_PQATTEST.srcs/sim_1/new/pqattest_tb.sv.

    TAG = KMAC128( K = tile_key,
                   X = TILE_ID || EPOCH || NONCE || MEASUREMENT,   (65 bytes)
                   S = "PQ-ATTEST-AUTH",
                   L )

Inputs are defined here in NATURAL (printed) byte order - byte 0 first.
The TB stores tags in RTL order (byte 0 at the LSB end), i.e. byte-reversed;
the '# printed ...' comment above each TB literal is the natural order, and this
script compares against that printed form directly.

Exit 0 iff all NIST self-tests pass AND all 8 vectors match. Exit 1 otherwise.
"""

import sys
import kmac128_ref as R

# Run the reference's own NIST self-test first: no vector is meaningful until
# the model reproduces the published KMAC128 samples.
R._selftest()
print()

# ---- Stage 7 inputs, NATURAL byte order (byte 0 first) --------------------
KEY_T    = bytes(range(32))                        # 00 01 .. 1f
KEY_MUT  = KEY_T[:31] + bytes([0x1e])             # last byte 0x1f -> 0x1e

TILE_01  = b"TILE_01"                              # 54 49 4c 45 5f 30 31
TILE_MUT = bytes([0x55]) + b"ILE_01"              # byte0 'T'(0x54) -> 0x55

EPOCH_1  = b"EPOCH_0001"
EPOCH_M  = b"EPOCH_0000"

NONCE_A  = bytes(range(16))                        # 00 01 .. 0f
NONCE_M  = bytes(range(15)) + bytes([0x0e])       # byte15 0x0f -> 0x0e

MEAS_M01 = bytes.fromhex("959b61960366c705b889e2c09ffaead296e296475f32a610732ab9eac293182a")
MEAS_MUT = bytes([0x94]) + MEAS_M01[1:]           # byte0 0x95 -> 0x94

CUSTOM   = b"PQ-ATTEST-AUTH"                       # the Stage 7 domain string


def transcript(tile, epoch, nonce, meas):
    x = tile + epoch + nonce + meas
    assert len(x) == 65, f"transcript is {len(x)} bytes, expected 65"
    return x


def tag(key, tile, epoch, nonce, meas, L_bits, custom):
    return R.kmac128(key, transcript(tile, epoch, nonce, meas),
                     L_bits // 8, custom).hex()


# ---- (name, computed, expected-printed-from-TB) ---------------------------
V01_inp = (KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_M01)
vectors = [
    ("V01 baseline",              tag(*V01_inp, 256, CUSTOM),
     "491c8ce777d0bf3577aa4fe87ec587ddf4da0e81a4df90e5b803e6641145600d"),
    ("V02 TILE_ID mutation",      tag(KEY_T, TILE_MUT, EPOCH_1, NONCE_A, MEAS_M01, 256, CUSTOM),
     "a7e665a930a394088765177b6739f43db657a672bc8e7f197dac6e18fdc1e494"),
    ("V03 EPOCH mutation",        tag(KEY_T, TILE_01, EPOCH_M, NONCE_A, MEAS_M01, 256, CUSTOM),
     "36e32c8f13889da2f94b5be48650d55cc7cdc6f145f9b02447b8b7ad3205c763"),
    ("V04 NONCE mutation",        tag(KEY_T, TILE_01, EPOCH_1, NONCE_M, MEAS_M01, 256, CUSTOM),
     "d89f3d5ab172d94045ac36392d273c69f3a20265d7225bfcb03313ee00269141"),
    ("V05 MEASUREMENT mutation",  tag(KEY_T, TILE_01, EPOCH_1, NONCE_A, MEAS_MUT, 256, CUSTOM),
     "ec85835dcf0017ab2df88ef35e07956b64f59312c99371d19ca8d600b3803ca3"),
    ("V06 KEY mutation",          tag(KEY_MUT, TILE_01, EPOCH_1, NONCE_A, MEAS_M01, 256, CUSTOM),
     "cd751ae4b6d193185a75641d376e8061ec5dac94c9486ad9c51e343ee85f441f"),
    ("V07 baseline L=128",        tag(*V01_inp, 128, CUSTOM),
     "dabd282cc70b742effb22ca5188d393d"),
    ("V08 empty customization",   tag(*V01_inp, 256, b""),
     "7cbc7c9e31ed3febc2ce55bd5e5c34cb1c3022861ba741fb21c617bd6ba1b1b4"),
]

print("Stage 7 golden vectors  (reference vs pqattest_tb.sv literal, printed order):")
allok = True
for name, got, exp in vectors:
    r = (got == exp)
    allok &= r
    print(f"  {'MATCH' if r else 'MISMATCH':8} {name}")
    if not r:
        print(f"      got {got}\n      exp {exp}")

# Cross-property the TB itself asserts: KMAC output length is absorbed, not
# truncated -> V07 (L=128) must NOT equal V01[:16] (L=256 truncated).
v01 = vectors[0][1]
v07 = vectors[6][1]
absorbed = (v07 != v01[:32])
allok &= absorbed
print(f"  {'MATCH' if absorbed else 'MISMATCH':8} V07 L=128 != V01 L=256 truncated (absorbed, not truncated)")

print()
if allok:
    print("ALL 8 STAGE-7 VECTORS MATCH THE TESTBENCH LITERALS")
    sys.exit(0)
else:
    print("STAGE-7 VECTOR MISMATCH")
    sys.exit(1)
