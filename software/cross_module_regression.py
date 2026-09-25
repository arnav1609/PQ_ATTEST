"""
PQ-Attest v1 — Cross-Module Python Regression

Complete software reference flow:

    Root Secret
        |
        v
    Tile-Key KDF
        |
        v
    Per-Tile Key
        |
        +----------------------+
        |                      |
        v                      v
    Measurement             Nonce
    SHA3-256                  |
        |                      |
        +----------+-----------+
                   |
                   v
          Runtime Attestation
              KMAC128
                   |
                   v
              256-bit Tag
                   |
                   v
               Verify
"""

from hashlib import sha3_256

from kmac128_ref import derive_tile_key
from attestation_ref import (
    generate_attestation_tag,
    verify_attestation,
)


# ============================================================
# Test Constants
# ============================================================

ROOT_SECRET = bytes.fromhex(
    "000102030405060708090a0b0c0d0e0f"
    "101112131415161718191a1b1c1d1e1f"
)

EPOCH_1 = b"EPOCH_0001"
EPOCH_2 = b"EPOCH_0002"

CONTEXT = b"PQ-ATTEST-KDF"

TILE_1 = b"TILE_01"
TILE_2 = b"TILE_02"

NONCE_1 = bytes.fromhex(
    "f55ba327291604f0e5be6651752398b7"
)

NONCE_2 = bytes.fromhex(
    "11111111111111111111111111111111"
)


# ============================================================
# Example Tile Configuration / IMEM
# ============================================================

CONFIG_1 = b"CONFIG_TILE_01_V1"

IMEM_1 = bytes.fromhex(
    "00112233445566778899aabbccddeeff"
    "102030405060708090a0b0c0d0e0f000"
)

CONFIG_2 = b"CONFIG_TILE_02_V1"

IMEM_2 = bytes.fromhex(
    "ffeeddccbbaa99887766554433221100"
    "f0e0d0c0b0a090807060504030201000"
)


# ============================================================
# Measurement
# ============================================================

def calculate_measurement(tile_id, config, imem):
    """
    M = SHA3-256(TILE_ID || CONFIG || IMEM)
    """

    return sha3_256(
        tile_id + config + imem
    ).digest()


# ============================================================
# Test Helper
# ============================================================

def check(name, condition):
    if condition:
        print(f"{name:<55} PASS")
        return 1
    else:
        print(f"{name:<55} FAIL")
        return 0


# ============================================================
# Main Regression
# ============================================================

def main():

    passed = 0
    total = 0

    print("PQ-Attest v1 Cross-Module Regression")
    print("=" * 70)

    # --------------------------------------------------------
    # 1. Generate Tile 1 key using KDF
    # --------------------------------------------------------

    tile1_key = derive_tile_key(
        ROOT_SECRET,
        TILE_1,
        EPOCH_1,
        CONTEXT,
        16
    )

    passed += check(
        "1. Tile 1 key derivation",
        tile1_key == bytes.fromhex(
            "9c699e785af03e632e2da3cbe9ede27c"
        )
    )
    total += 1

    # --------------------------------------------------------
    # 2. Generate Tile 2 key using KDF
    # --------------------------------------------------------

    tile2_key = derive_tile_key(
        ROOT_SECRET,
        TILE_2,
        EPOCH_1,
        CONTEXT,
        16
    )

    passed += check(
        "2. Tile 2 key derivation",
        tile2_key == bytes.fromhex(
            "f30ddb5b98f18616cfd5869f773fe53a"
        )
    )
    total += 1

    # --------------------------------------------------------
    # 3. Tile keys must be different
    # --------------------------------------------------------

    passed += check(
        "3. Different tiles produce different keys",
        tile1_key != tile2_key
    )
    total += 1

    # --------------------------------------------------------
    # 4. Calculate Tile 1 measurement
    # --------------------------------------------------------

    measurement1 = calculate_measurement(
        TILE_1,
        CONFIG_1,
        IMEM_1
    )

    passed += check(
        "4. Tile 1 measurement is 256-bit",
        len(measurement1) == 32
    )
    total += 1

    # --------------------------------------------------------
    # 5. Measurement is deterministic
    # --------------------------------------------------------

    measurement1_again = calculate_measurement(
        TILE_1,
        CONFIG_1,
        IMEM_1
    )

    passed += check(
        "5. Measurement is deterministic",
        measurement1_again == measurement1
    )
    total += 1

    # --------------------------------------------------------
    # 6. Generate valid attestation
    # --------------------------------------------------------

    tag1 = generate_attestation_tag(
        tile_key=tile1_key,
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_1,
        measurement=measurement1
    )

    passed += check(
        "6. Attestation tag generated",
        len(tag1) == 32
    )
    total += 1

    # --------------------------------------------------------
    # 7. Valid attestation verifies
    # --------------------------------------------------------

    result = verify_attestation(
        tile_key=tile1_key,
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_1,
        measurement=measurement1,
        received_tag=tag1
    )

    passed += check(
        "7. Valid attestation verifies",
        result is True
    )
    total += 1

    # --------------------------------------------------------
    # 8. Wrong nonce fails
    # --------------------------------------------------------

    result = verify_attestation(
        tile_key=tile1_key,
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_2,
        measurement=measurement1,
        received_tag=tag1
    )

    passed += check(
        "8. Wrong nonce rejected",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 9. Modified measurement fails
    # --------------------------------------------------------

    modified_measurement = bytearray(measurement1)
    modified_measurement[0] ^= 0x01
    modified_measurement = bytes(modified_measurement)

    result = verify_attestation(
        tile_key=tile1_key,
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_1,
        measurement=modified_measurement,
        received_tag=tag1
    )

    passed += check(
        "9. Modified measurement rejected",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 10. Wrong tile key fails
    # --------------------------------------------------------

    result = verify_attestation(
        tile_key=tile2_key,
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_1,
        measurement=measurement1,
        received_tag=tag1
    )

    passed += check(
        "10. Wrong tile key rejected",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 11. Wrong tile ID fails
    # --------------------------------------------------------

    result = verify_attestation(
        tile_key=tile1_key,
        tile_id=TILE_2,
        epoch=EPOCH_1,
        nonce=NONCE_1,
        measurement=measurement1,
        received_tag=tag1
    )

    passed += check(
        "11. Wrong tile ID rejected",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 12. Wrong epoch fails
    # --------------------------------------------------------

    result = verify_attestation(
        tile_key=tile1_key,
        tile_id=TILE_1,
        epoch=EPOCH_2,
        nonce=NONCE_1,
        measurement=measurement1,
        received_tag=tag1
    )

    passed += check(
        "12. Wrong epoch rejected",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 13. Tile 2 gets independent measurement
    # --------------------------------------------------------

    measurement2 = calculate_measurement(
        TILE_2,
        CONFIG_2,
        IMEM_2
    )

    passed += check(
        "13. Tile 2 measurement differs",
        measurement2 != measurement1
    )
    total += 1

    # --------------------------------------------------------
    # 14. Tile 2 valid attestation
    # --------------------------------------------------------

    tag2 = generate_attestation_tag(
        tile_key=tile2_key,
        tile_id=TILE_2,
        epoch=EPOCH_1,
        nonce=NONCE_1,
        measurement=measurement2
    )

    result = verify_attestation(
        tile_key=tile2_key,
        tile_id=TILE_2,
        epoch=EPOCH_1,
        nonce=NONCE_1,
        measurement=measurement2,
        received_tag=tag2
    )

    passed += check(
        "14. Tile 2 valid attestation verifies",
        result is True
    )
    total += 1

    # --------------------------------------------------------
    # 15. Replay old Tile 1 tag with fresh nonce fails
    # --------------------------------------------------------

    result = verify_attestation(
        tile_key=tile1_key,
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_2,
        measurement=measurement1,
        received_tag=tag1
    )

    passed += check(
        "15. Replay with fresh nonce rejected",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 16. Complete chain is deterministic
    # --------------------------------------------------------

    tile1_key_repeat = derive_tile_key(
        ROOT_SECRET,
        TILE_1,
        EPOCH_1,
        CONTEXT,
        16
    )

    measurement1_repeat = calculate_measurement(
        TILE_1,
        CONFIG_1,
        IMEM_1
    )

    tag1_repeat = generate_attestation_tag(
        tile_key=tile1_key_repeat,
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_1,
        measurement=measurement1_repeat
    )

    passed += check(
        "16. Complete chain is deterministic",
        (
            tile1_key_repeat == tile1_key
            and measurement1_repeat == measurement1
            and tag1_repeat == tag1
        )
    )
    total += 1

    # --------------------------------------------------------
    # Summary
    # --------------------------------------------------------

    failed = total - passed

    print("=" * 70)
    print(f"PASSED : {passed} / {total}")
    print(f"FAILED : {failed} / {total}")

    if passed == total:
        print("\nCROSS-MODULE REGRESSION PASSED")
    else:
        print("\nCROSS-MODULE REGRESSION FAILED")
        raise SystemExit(1)


if __name__ == "__main__":
    main()