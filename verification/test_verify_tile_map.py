import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

VERIFIER = ROOT / "verification" / "verify_tile_map.py"
SOURCE = ROOT / "NOC_PQATTEST.srcs" / "sources_1" / "new" / "NOC_PKG.sv"


def run_verifier(source: Path):
    return subprocess.run(
        [
            sys.executable,
            str(VERIFIER),
            "--source",
            str(source),
        ],
        capture_output=True,
        text=True,
    )


def load_source():
    return SOURCE.read_text(encoding="utf-8")


def write_mutation(tmp_path, name, text):
    path = tmp_path / f"{name}.sv"
    path.write_text(text, encoding="utf-8")
    return path


def test_correct_map_passes():
    result = run_verifier(SOURCE)

    assert result.returncode == 0
    assert "STATUS              : PASS" in result.stdout


def test_duplicate_tile_id_fails(tmp_path):
    text = load_source()

    # Change the actual enum assignment.
    pattern = r"(TILE_SPOOF\s*=\s*)'d5"
    mutated, count = re.subn(pattern, r"\g<1>'d4", text, count=1)

    assert count == 1, "Could not locate TILE_SPOOF enum assignment"

    path = write_mutation(tmp_path, "duplicate_tile_id", mutated)
    result = run_verifier(path)

    assert result.returncode != 0
    assert "FAIL" in result.stdout


def test_duplicate_coordinate_fails(tmp_path):
    text = load_source()

    # Change SPOOF coordinate from (2,1) to ROT's coordinate (1,1).
    pattern = (
        r"(TILE_SPOOF\s*:\s*begin\s+"
        r"coord\.x\s*=\s*)3'd2"
        r"(;\s*coord\.y\s*=\s*)3'd1"
    )

    mutated, count = re.subn(
        pattern,
        r"\g<1>3'd1\g<2>3'd1",
        text,
        count=1,
        flags=re.DOTALL,
    )

    assert count == 1, "Could not locate TILE_SPOOF coordinate case"

    path = write_mutation(tmp_path, "duplicate_coordinate", mutated)
    result = run_verifier(path)

    assert result.returncode != 0
    assert "FAIL" in result.stdout


def test_out_of_bounds_coordinate_fails(tmp_path):
    text = load_source()

    # Change SPOOF x coordinate from 2 to 3.
    pattern = (
        r"(TILE_SPOOF\s*:\s*begin\s+"
        r"coord\.x\s*=\s*)3'd2"
    )

    mutated, count = re.subn(
        pattern,
        r"\g<1>3'd3",
        text,
        count=1,
        flags=re.DOTALL,
    )

    assert count == 1, "Could not locate TILE_SPOOF x coordinate"

    path = write_mutation(tmp_path, "out_of_bounds", mutated)
    result = run_verifier(path)

    assert result.returncode != 0
    assert "FAIL" in result.stdout


def test_missing_tile_mapping_fails(tmp_path):
    text = load_source()

    # Remove the entire TILE_SPOOF case from tile_to_coord().
    pattern = (
        r"\s*TILE_SPOOF\s*:\s*begin.*?"
        r"\bend\b"
    )

    mutated, count = re.subn(
        pattern,
        "",
        text,
        count=1,
        flags=re.DOTALL,
    )

    assert count == 1, "Could not locate TILE_SPOOF mapping case"

    path = write_mutation(tmp_path, "missing_tile_mapping", mutated)
    result = run_verifier(path)

    assert result.returncode != 0
    assert "FAIL" in result.stdout