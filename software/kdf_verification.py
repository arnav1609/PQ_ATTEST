from kmac128_ref import derive_tile_key


ROOT_SECRET = bytes.fromhex(
    "000102030405060708090a0b0c0d0e0f"
    "101112131415161718191a1b1c1d1e1f"
)


def check(name, condition):
    if condition:
        print(f"{name:<32} PASS")
        return 1
    else:
        print(f"{name:<32} FAIL")
        return 0


def main():

    passed = 0
    failed = 0

    # --------------------------------------------------------
    # V01: Same inputs -> same key
    # --------------------------------------------------------

    key1 = derive_tile_key(
        ROOT_SECRET,
        b"TILE_01",
        b"EPOCH_0001",
        b"PQ-ATTEST-KDF",
        16
    )

    key2 = derive_tile_key(
        ROOT_SECRET,
        b"TILE_01",
        b"EPOCH_0001",
        b"PQ-ATTEST-KDF",
        16
    )

    if check("Same inputs", key1 == key2):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # V02: Tile separation
    # --------------------------------------------------------

    tile2_key = derive_tile_key(
        ROOT_SECRET,
        b"TILE_02",
        b"EPOCH_0001",
        b"PQ-ATTEST-KDF",
        16
    )

    if check("Tile separation", key1 != tile2_key):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # V03: Epoch separation
    # --------------------------------------------------------

    epoch2_key = derive_tile_key(
        ROOT_SECRET,
        b"TILE_01",
        b"EPOCH_0002",
        b"PQ-ATTEST-KDF",
        16
    )

    if check("Epoch separation", key1 != epoch2_key):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # V04: Context separation
    # --------------------------------------------------------

    auth_key = derive_tile_key(
        ROOT_SECRET,
        b"TILE_01",
        b"EPOCH_0001",
        b"PQ-ATTEST-AUTH",
        16
    )

    if check("Context separation", key1 != auth_key):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # V05: Root-secret separation
    # --------------------------------------------------------

    different_root = bytes.fromhex(
        "101112131415161718191a1b1c1d1e1f"
        "202122232425262728292a2b2c2d2e2f"
    )

    different_root_key = derive_tile_key(
        different_root,
        b"TILE_01",
        b"EPOCH_0001",
        b"PQ-ATTEST-KDF",
        16
    )

    if check(
        "Root-secret separation",
        key1 != different_root_key
    ):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # Empty customization/context
    # --------------------------------------------------------

    empty_context_key = derive_tile_key(
        ROOT_SECRET,
        b"TILE_01",
        b"EPOCH_0001",
        b"",
        16
    )

    if check(
        "Empty context",
        len(empty_context_key) == 16
    ):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # 16-byte output
    # --------------------------------------------------------

    if check(
        "16-byte output",
        len(key1) == 16
    ):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # 32-byte output
    # --------------------------------------------------------

    key32 = derive_tile_key(
        ROOT_SECRET,
        b"TILE_01",
        b"EPOCH_0001",
        b"PQ-ATTEST-KDF",
        32
    )

    if check(
        "32-byte output",
        len(key32) == 32
    ):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # Invalid output length: zero
    # --------------------------------------------------------

    try:

        derive_tile_key(
            ROOT_SECRET,
            b"TILE_01",
            b"EPOCH_0001",
            b"PQ-ATTEST-KDF",
            0
        )

        result = False

    except ValueError:

        result = True

    if check(
        "Zero-length rejection",
        result
    ):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # Invalid output length: > 32 bytes
    # --------------------------------------------------------

    try:

        derive_tile_key(
            ROOT_SECRET,
            b"TILE_01",
            b"EPOCH_0001",
            b"PQ-ATTEST-KDF",
            64
        )

        result = False

    except ValueError:

        result = True

    if check(
        "Large-length rejection",
        result
    ):
        passed += 1
    else:
        failed += 1

    # --------------------------------------------------------
    # Summary
    # --------------------------------------------------------

    print()
    print("=" * 60)
    print(f"PASSED TESTS : {passed}")
    print(f"FAILED TESTS : {failed}")
    print("=" * 60)

    if failed == 0:
        print()
        print("STAGE 5 PYTHON KDF VERIFICATION: PASS")
    else:
        print()
        print("STAGE 5 PYTHON KDF VERIFICATION: FAIL")
        raise SystemExit(1)


if __name__ == "__main__":
    main()