from pathlib import Path
import sys

# Allow importing verification/xsim_parser.py
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from verification.xsim_parser import parse_xsim_file


TEST_DIR = Path(__file__).resolve().parent


def check_case(
    filename: str,
    expected_status: str,
    expected_result,
    expected_tb_errors: int,
    expected_tb_errors_detected: int,
    expected_fatals: int,
    expected_assertions: int,
    expected_simulator_errors: int,
    expected_termination: str,
):
    path = TEST_DIR / filename
    result = parse_xsim_file(path)

    assert result.status == expected_status, (
        f"{filename}: status={result.status}, "
        f"expected={expected_status}"
    )

    assert result.result == expected_result, (
        f"{filename}: result={result.result}, "
        f"expected={expected_result}"
    )

    assert result.tb_errors == expected_tb_errors, (
        f"{filename}: tb_errors={result.tb_errors}, "
        f"expected={expected_tb_errors}"
    )

    assert result.tb_errors_detected == expected_tb_errors_detected, (
        f"{filename}: tb_errors_detected={result.tb_errors_detected}, "
        f"expected={expected_tb_errors_detected}"
    )

    assert result.fatal_count == expected_fatals, (
        f"{filename}: fatal_count={result.fatal_count}, "
        f"expected={expected_fatals}"
    )

    assert result.assertion_failures == expected_assertions, (
        f"{filename}: assertion_failures={result.assertion_failures}, "
        f"expected={expected_assertions}"
    )

    assert result.simulator_errors == expected_simulator_errors, (
        f"{filename}: simulator_errors={result.simulator_errors}, "
        f"expected={expected_simulator_errors}"
    )

    assert result.termination_status == expected_termination, (
        f"{filename}: termination={result.termination_status}, "
        f"expected={expected_termination}"
    )

    print(f"PASS: {filename}")


def main():
    check_case(
        "sample_pass.log",
        "PASS",
        "PASS",
        0,
        0,
        0,
        0,
        0,
        "NORMAL",
    )

    check_case(
        "sample_fatal.log",
        "FAIL",
        "PASS",
        0,
        0,
        2,
        0,
        0,
        "FATAL",
    )

    check_case(
        "sample_tb_error.log",
        "FAIL",
        "PASS",
        1,
        1,
        0,
        0,
        0,
        "UNKNOWN",
    )

    check_case(
        "sample_assertion.log",
        "FAIL",
        "PASS",
        0,
        0,
        0,
        1,
        0,
        "UNKNOWN",
    )

    check_case(
        "sample_missing_result.log",
        "FAIL",
        None,
        0,
        0,
        0,
        0,
        0,
        "UNKNOWN",
    )

    check_case(
        "sample_false_error.log",
        "PASS",
        "PASS",
        0,
        0,
        0,
        0,
        0,
        "NORMAL",
    )

    print()
    print("=" * 60)
    print("P0-1 XSIM PARSER TESTS: ALL PASS")
    print("=" * 60)


if __name__ == "__main__":
    main()