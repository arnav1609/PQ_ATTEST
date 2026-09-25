from attestation_ref import generate_attestation_tag, verify_attestation


# ============================================================
# Test Constants
# ============================================================

TILE_KEY = bytes.fromhex(
    "9c699e785af03e632e2da3cbe9ede27c"
)

TILE_ID = b"TILE_01"

EPOCH = b"EPOCH_0001"

NONCE = bytes.fromhex(
    "f55ba327291604f0e5be6651752398b7"
)

MEASUREMENT = bytes.fromhex(
    "959b61960366c705b889e2c09ffaead296e296475f32a610732ab9eac293182a"
)


def check(name, condition):
    if condition:
        print(f"{name:<45} PASS")
        return 1
    else:
        print(f"{name:<45} FAIL")
        return 0


def main():

    passed = 0
    failed = 0
    total = 0

    print("PQ-Attest Runtime Attestation Tests")
    print("=" * 60)

    # --------------------------------------------------------
    # Base valid tag
    # --------------------------------------------------------

    valid_tag = generate_attestation_tag(
        TILE_KEY,
        TILE_ID,
        EPOCH,
        NONCE,
        MEASUREMENT
    )

    # --------------------------------------------------------
    # 1. Valid attestation
    # --------------------------------------------------------

    result = verify_attestation(
        TILE_KEY,
        TILE_ID,
        EPOCH,
        NONCE,
        MEASUREMENT,
        valid_tag
    )

    passed += check(
        "1. Valid attestation",
        result is True
    )
    total += 1

    # --------------------------------------------------------
    # 2. Same inputs produce same tag
    # --------------------------------------------------------

    tag_again = generate_attestation_tag(
        TILE_KEY,
        TILE_ID,
        EPOCH,
        NONCE,
        MEASUREMENT
    )

    passed += check(
        "2. Same inputs produce same tag",
        tag_again == valid_tag
    )
    total += 1

    # --------------------------------------------------------
    # 3. Different nonce changes tag
    # --------------------------------------------------------

    different_nonce = bytes.fromhex(
        "00000000000000000000000000000000"
    )

    different_nonce_tag = generate_attestation_tag(
        TILE_KEY,
        TILE_ID,
        EPOCH,
        different_nonce,
        MEASUREMENT
    )

    passed += check(
        "3. Different nonce -> tag changes",
        different_nonce_tag != valid_tag
    )
    total += 1

    # --------------------------------------------------------
    # 4. Wrong nonce fails verification
    # --------------------------------------------------------

    result = verify_attestation(
        TILE_KEY,
        TILE_ID,
        EPOCH,
        different_nonce,
        MEASUREMENT,
        valid_tag
    )

    passed += check(
        "4. Wrong nonce -> verification fails",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 5. Modified measurement fails verification
    # --------------------------------------------------------

    modified_measurement = bytes.fromhex(
        "00000000000000000000000000000000"
        "00000000000000000000000000000000"
    )

    result = verify_attestation(
        TILE_KEY,
        TILE_ID,
        EPOCH,
        NONCE,
        modified_measurement,
        valid_tag
    )

    passed += check(
        "5. Modified measurement -> verification fails",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 6. Wrong tile key fails verification
    # --------------------------------------------------------

    wrong_tile_key = bytes.fromhex(
        "00000000000000000000000000000000"
    )

    result = verify_attestation(
        wrong_tile_key,
        TILE_ID,
        EPOCH,
        NONCE,
        MEASUREMENT,
        valid_tag
    )

    passed += check(
        "6. Wrong tile key -> verification fails",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 7. Wrong tile ID fails verification
    # --------------------------------------------------------

    wrong_tile_id = b"TILE_02"

    result = verify_attestation(
        TILE_KEY,
        wrong_tile_id,
        EPOCH,
        NONCE,
        MEASUREMENT,
        valid_tag
    )

    passed += check(
        "7. Wrong tile ID -> verification fails",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 8. Wrong epoch fails verification
    # --------------------------------------------------------

    wrong_epoch = b"EPOCH_0002"

    result = verify_attestation(
        TILE_KEY,
        TILE_ID,
        wrong_epoch,
        NONCE,
        MEASUREMENT,
        valid_tag
    )

    passed += check(
        "8. Wrong epoch -> verification fails",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 9. Wrong received tag fails verification
    # --------------------------------------------------------

    wrong_tag = bytes.fromhex(
        "00000000000000000000000000000000"
        "00000000000000000000000000000000"
    )

    result = verify_attestation(
        TILE_KEY,
        TILE_ID,
        EPOCH,
        NONCE,
        MEASUREMENT,
        wrong_tag
    )

    passed += check(
        "9. Wrong received tag -> verification fails",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # 10. Replay attempt with old tag and fresh nonce fails
    # --------------------------------------------------------

    replay_nonce = bytes.fromhex(
        "11111111111111111111111111111111"
    )

    result = verify_attestation(
        TILE_KEY,
        TILE_ID,
        EPOCH,
        replay_nonce,
        MEASUREMENT,
        valid_tag
    )

    passed += check(
        "10. Replay with old tag -> verification fails",
        result is False
    )
    total += 1

    # --------------------------------------------------------
    # Summary
    # --------------------------------------------------------

    failed = total - passed

    print("=" * 60)
    print(f"PASSED : {passed} / {total}")
    print(f"FAILED : {failed} / {total}")

    if passed == total:
        print("\nATTESTATION VERIFICATION PASSED")
    else:
        print("\nATTESTATION VERIFICATION FAILED")
        raise SystemExit(1)


if __name__ == "__main__":
    main()