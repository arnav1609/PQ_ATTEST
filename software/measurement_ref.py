"""
PQ-Attest Measurement Golden Reference
=======================================

Frozen measurement definition:

    M[n] = SHA3-256(TILE_ID || CONFIG || IMEM)

The SHA3-256 operation uses the project's existing,
verified reference implementation.
"""

from sha3_256_ref import (
    sha3_pad,
    absorb_block,
    squeeze
)

from keccak_ref import (
    create_state,
    keccak_f1600
)


# ============================================================
# Parameters
# ============================================================

RATE_BYTES = 136
OUTPUT_BYTES = 32


# ============================================================
# SHA3-256 reference wrapper
# ============================================================

def sha3_256_reference(message: bytes) -> bytes:
    """
    Calculate SHA3-256 using the existing PQ-Attest
    Keccak/SHA3 reference implementation.
    """

    # --------------------------------------------------------
    # SHA3 padding
    # --------------------------------------------------------

    padded = sha3_pad(message)

    # --------------------------------------------------------
    # Initial Keccak state
    # --------------------------------------------------------

    state = create_state()

    # --------------------------------------------------------
    # Absorb every 136-byte block
    #
    # absorb_block() modifies the state in place.
    # keccak_f1600() returns the new state.
    # --------------------------------------------------------

    for offset in range(0, len(padded), RATE_BYTES):

        block = padded[offset:offset + RATE_BYTES]

        absorb_block(state, block)

        state = keccak_f1600(state)

    # --------------------------------------------------------
    # Squeeze 256-bit digest
    # --------------------------------------------------------

    digest = squeeze(state, OUTPUT_BYTES)

    return digest


# ============================================================
# PQ-Attest Measurement
# ============================================================

def measure_tile(
    tile_id: bytes,
    config: bytes,
    imem: bytes
) -> bytes:
    """
    Calculate the PQ-Attest tile measurement.

    M[n] = SHA3-256(TILE_ID || CONFIG || IMEM)

    No separators or lengths are inserted.
    """

    measurement_input = (
        tile_id
        + config
        + imem
    )

    return sha3_256_reference(measurement_input)


# ============================================================
# Hex helper
# ============================================================

def measurement_hex(
    tile_id: bytes,
    config: bytes,
    imem: bytes
) -> str:

    return measure_tile(
        tile_id,
        config,
        imem
    ).hex()


# ============================================================
# Test Vectors
# ============================================================

def run_test_vectors():

    print("=" * 70)
    print("PQ-ATTEST MEASUREMENT GOLDEN REFERENCE")
    print("=" * 70)


    # ========================================================
    # V01
    # ========================================================

    tile_id = b"TILE_01"

    config = bytes.fromhex(
        "000102030405060708090a0b0c0d0e0f"
    )

    imem = bytes.fromhex(
        "101112131415161718191a1b1c1d1e1f"
    )

    result = measure_tile(
        tile_id,
        config,
        imem
    )

    expected = __import__("hashlib").sha3_256(
        tile_id + config + imem
    ).digest()

    print()
    print("V01")
    print("-" * 70)
    print("TILE_ID :", tile_id.hex())
    print("CONFIG  :", config.hex())
    print("IMEM    :", imem.hex())
    print("M       :", result.hex())
    print("Expected:", expected.hex())
    print("Status  :", "PASS" if result == expected else "FAIL")


    # ========================================================
    # V02 - Different TILE_ID
    # ========================================================

    tile_id = b"TILE_02"

    config = bytes.fromhex(
        "000102030405060708090a0b0c0d0e0f"
    )

    imem = bytes.fromhex(
        "101112131415161718191a1b1c1d1e1f"
    )

    result = measure_tile(
        tile_id,
        config,
        imem
    )

    expected = __import__("hashlib").sha3_256(
        tile_id + config + imem
    ).digest()

    print()
    print("V02")
    print("-" * 70)
    print("TILE_ID :", tile_id.hex())
    print("CONFIG  :", config.hex())
    print("IMEM    :", imem.hex())
    print("M       :", result.hex())
    print("Expected:", expected.hex())
    print("Status  :", "PASS" if result == expected else "FAIL")


    # ========================================================
    # V03 - Different CONFIG
    # ========================================================

    tile_id = b"TILE_01"

    config = bytes.fromhex(
        "ff000102030405060708090a0b0c0d0e"
    )

    imem = bytes.fromhex(
        "101112131415161718191a1b1c1d1e1f"
    )

    result = measure_tile(
        tile_id,
        config,
        imem
    )

    expected = __import__("hashlib").sha3_256(
        tile_id + config + imem
    ).digest()

    print()
    print("V03")
    print("-" * 70)
    print("TILE_ID :", tile_id.hex())
    print("CONFIG  :", config.hex())
    print("IMEM    :", imem.hex())
    print("M       :", result.hex())
    print("Expected:", expected.hex())
    print("Status  :", "PASS" if result == expected else "FAIL")


    # ========================================================
    # V04 - Different IMEM
    # ========================================================

    tile_id = b"TILE_01"

    config = bytes.fromhex(
        "000102030405060708090a0b0c0d0e0f"
    )

    imem = bytes.fromhex(
        "ff1112131415161718191a1b1c1d1e1f"
    )

    result = measure_tile(
        tile_id,
        config,
        imem
    )

    expected = __import__("hashlib").sha3_256(
        tile_id + config + imem
    ).digest()

    print()
    print("V04")
    print("-" * 70)
    print("TILE_ID :", tile_id.hex())
    print("CONFIG  :", config.hex())
    print("IMEM    :", imem.hex())
    print("M       :", result.hex())
    print("Expected:", expected.hex())
    print("Status  :", "PASS" if result == expected else "FAIL")


    # ========================================================
    # V05 - Empty CONFIG and IMEM
    # ========================================================

    tile_id = b"TILE_01"

    config = b""
    imem = b""

    result = measure_tile(
        tile_id,
        config,
        imem
    )

    expected = __import__("hashlib").sha3_256(
        tile_id + config + imem
    ).digest()

    print()
    print("V05")
    print("-" * 70)
    print("TILE_ID :", tile_id.hex())
    print("CONFIG  :", config.hex())
    print("IMEM    :", imem.hex())
    print("M       :", result.hex())
    print("Expected:", expected.hex())
    print("Status  :", "PASS" if result == expected else "FAIL")


    # ========================================================
    # V06 - Larger deterministic input
    # ========================================================

    tile_id = b"TILE_01"

    config = bytes(range(64))

    imem = bytes(range(64, 128))

    result = measure_tile(
        tile_id,
        config,
        imem
    )

    expected = __import__("hashlib").sha3_256(
        tile_id + config + imem
    ).digest()

    print()
    print("V06")
    print("-" * 70)
    print("TILE_ID :", tile_id.hex())
    print("CONFIG  :", config.hex())
    print("IMEM    :", imem.hex())
    print("M       :", result.hex())
    print("Expected:", expected.hex())
    print("Status  :", "PASS" if result == expected else "FAIL")


    # ========================================================
    # Summary
    # ========================================================

    print()
    print("=" * 70)
    print("MEASUREMENT REFERENCE COMPLETE")
    print("=" * 70)


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":
    run_test_vectors()