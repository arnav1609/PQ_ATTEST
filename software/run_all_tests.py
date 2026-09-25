"""
PQ-Attest v1 — Unified Python Test Runner
-------------------------------------------

Runs all Python KATs and regressions and reports a
single PASS/FAIL result.

Usage:
    python software/run_all_tests.py
"""

import subprocess
import sys
import os
import time


# ============================================================
# Test Suites
# ============================================================

TEST_SUITES = [

    {
        "name": "KMAC128 NIST KAT",
        "script": "software/kmac128_ref.py",
    },

    {
        "name": "Measurement Reference",
        "script": "software/measurement_ref.py",
    },

    {
        "name": "KDF Golden Vectors",
        "script": "software/kdf_vectors.py",
    },

    {
        "name": "KDF Verification",
        "script": "software/kdf_verification.py",
    },

    {
        "name": "Attestation Vectors",
        "script": "software/attestation_vectors.py",
    },

    {
        "name": "Attestation Protocol",
        "script": "software/attestation_protocol.py",
    },

    {
        "name": "Security-Property Regression",
        "script": "software/security_regression.py",
    },

    {
        "name": "Cross-Module Regression",
        "script": "software/cross_module_regression.py",
    },

]


# ============================================================
# Runner
# ============================================================

def run_suite(name, script, python, cwd):
    """
    Run a single test suite as a subprocess.

    Returns (name, passed, elapsed_seconds).
    """

    start = time.time()

    result = subprocess.run(
        [python, script],
        cwd=cwd,
        capture_output=True,
        text=True,
    )

    elapsed = time.time() - start

    return (
        name,
        result.returncode == 0,
        elapsed,
        result.stdout,
        result.stderr,
    )


def main():

    python = sys.executable

    # Run from the project root
    cwd = os.path.dirname(
        os.path.dirname(
            os.path.abspath(__file__)
        )
    )

    print()
    print("=" * 70)
    print("PQ-Attest v1 — Full Python Regression")
    print("=" * 70)
    print()

    results = []

    for suite in TEST_SUITES:

        name = suite["name"]
        script = suite["script"]

        print(f"Running: {name} ...", end=" ", flush=True)

        name, passed, elapsed, stdout, stderr = run_suite(
            name,
            script,
            python,
            cwd,
        )

        status = "PASS" if passed else "FAIL"

        print(f"{status}  ({elapsed:.2f}s)")

        results.append((name, passed, elapsed))

        if not passed and stderr:
            print(f"  stderr: {stderr.strip()}")

    # --------------------------------------------------------
    # Summary
    # --------------------------------------------------------

    print()
    print("=" * 70)
    print(f"{'Suite':<40} {'Result':<8} {'Time':>8}")
    print("-" * 70)

    total_pass = 0
    total_fail = 0
    total_time = 0.0

    for name, passed, elapsed in results:

        status = "PASS" if passed else "FAIL"

        print(
            f"{name:<40} {status:<8} {elapsed:>7.2f}s"
        )

        if passed:
            total_pass += 1
        else:
            total_fail += 1

        total_time += elapsed

    print("-" * 70)
    print(
        f"{'TOTAL':<40} "
        f"{total_pass}P/{total_fail}F"
        f"  {total_time:>7.2f}s"
    )
    print("=" * 70)

    if total_fail == 0:
        print()
        print("*" * 70)
        print("  ALL PYTHON TESTS PASSED")
        print("*" * 70)
        print()
    else:
        print()
        print("!" * 70)
        print(f"  {total_fail} SUITE(S) FAILED")
        print("!" * 70)
        print()
        sys.exit(1)


if __name__ == "__main__":
    main()
