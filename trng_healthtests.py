import math
import random


# ============================================================
# PQ-Attest TRNG Health / Statistical Tests
# ============================================================

TOTAL_BITS = 1_000_000


def bytes_to_bits(data):
    """Convert bytes to a list of bits, MSB first."""

    bits = []

    for byte in data:
        for i in range(7, -1, -1):
            bits.append((byte >> i) & 1)

    return bits


def monobit_test(bits):
    """
    Frequency / monobit test.

    Checks whether the number of 0s and 1s is approximately balanced.
    """

    n = len(bits)

    ones = sum(bits)
    zeros = n - ones

    s = abs(ones - zeros) / math.sqrt(n)

    p_value = math.erfc(s / math.sqrt(2))

    return {
        "ones": ones,
        "zeros": zeros,
        "p_value": p_value,
        "pass": p_value >= 0.01,
    }


def runs_test(bits):
    """
    NIST-style runs test.

    Checks whether transitions between 0 and 1 occur at a reasonable rate.
    """

    n = len(bits)

    ones = sum(bits)
    pi = ones / n

    # Prerequisite for the runs test.
    if abs(pi - 0.5) >= 2 / math.sqrt(n):
        return {
            "runs": None,
            "p_value": 0.0,
            "pass": False,
            "reason": "Monobit prerequisite failed",
        }

    runs = 1

    for i in range(1, n):
        if bits[i] != bits[i - 1]:
            runs += 1

    numerator = abs(
        runs - (2 * n * pi * (1 - pi))
    )

    denominator = (
        2
        * math.sqrt(2 * n)
        * pi
        * (1 - pi)
    )

    p_value = math.erfc(
        numerator / denominator
    )

    return {
        "runs": runs,
        "p_value": p_value,
        "pass": p_value >= 0.01,
    }


def min_entropy_estimate(bits):
    """
    Simple min-entropy estimate based on the most frequent symbol.

    H_min = -log2(max(P(0), P(1)))

    This is a basic estimate for demonstration.
    It is NOT a complete SP 800-90B entropy assessment.
    """

    n = len(bits)

    zeros = bits.count(0)
    ones = n - zeros

    p_max = max(zeros, ones) / n

    entropy = -math.log2(p_max)

    return {
        "entropy_per_bit": entropy,
        "pass": entropy >= 0.9,
    }


def generate_random_bits(n):
    """Generate synthetic random bits for testing."""

    return [random.getrandbits(1) for _ in range(n)]


def generate_bad_bits(n):
    """
    Generate deliberately biased data.

    Used to verify that the tests can detect bad entropy.
    """

    return [
        1 if random.random() < 0.90 else 0
        for _ in range(n)
    ]


def run_tests(name, bits):

    print()
    print("=" * 60)
    print(name)
    print("=" * 60)

    print(f"Number of bits: {len(bits):,}")

    # --------------------------------------------------------
    # Monobit
    # --------------------------------------------------------

    mono = monobit_test(bits)

    print()
    print("Monobit Test")
    print(f"  Ones       : {mono['ones']:,}")
    print(f"  Zeros      : {mono['zeros']:,}")
    print(f"  P-value    : {mono['p_value']:.6f}")
    print(f"  Result     : {'PASS' if mono['pass'] else 'FAIL'}")

    # --------------------------------------------------------
    # Runs
    # --------------------------------------------------------

    runs = runs_test(bits)

    print()
    print("Runs Test")

    if runs["runs"] is None:
        print(f"  Result     : FAIL")
        print(f"  Reason     : {runs['reason']}")
    else:
        print(f"  Runs       : {runs['runs']:,}")
        print(f"  P-value    : {runs['p_value']:.6f}")
        print(f"  Result     : {'PASS' if runs['pass'] else 'FAIL'}")

    # --------------------------------------------------------
    # Min entropy
    # --------------------------------------------------------

    entropy = min_entropy_estimate(bits)

    print()
    print("Min-Entropy Estimate")
    print(
        f"  H_min      : "
        f"{entropy['entropy_per_bit']:.6f} bits/bit"
    )
    print(
        f"  Requirement: >= 0.9 bits/bit"
    )
    print(
        f"  Result     : "
        f"{'PASS' if entropy['pass'] else 'FAIL'}"
    )

    print()


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":

    print("PQ-Attest TRNG Health Test")
    print("==========================")

    # --------------------------------------------------------
    # Test 1: synthetic good randomness
    # --------------------------------------------------------

    random.seed(12345)

    good_bits = generate_random_bits(TOTAL_BITS)

    run_tests(
        "TEST 1: Synthetic Random Data",
        good_bits
    )

    # --------------------------------------------------------
    # Test 2: deliberately biased source
    # --------------------------------------------------------

    random.seed(12345)

    bad_bits = generate_bad_bits(TOTAL_BITS)

    run_tests(
        "TEST 2: Deliberately Biased Data",
        bad_bits
    )