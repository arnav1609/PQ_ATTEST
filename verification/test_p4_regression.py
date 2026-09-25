import pytest
import json
import copy
from pathlib import Path
from verification.p4_regression import verify_cross_module

def get_artifacts():
    sv = "NOC_PQATTEST.srcs/sources_1/new/NOC_PKG.sv"
    matrix = json.loads(Path("software/noc_pair_matrix.json").read_text())
    traffic = json.loads(Path("software/noc_traffic_vectors.json").read_text())
    scenarios = json.loads(Path("software/integration_scenarios.json").read_text())
    return sv, matrix, traffic, scenarios

def test_correct_artifacts():
    sv, matrix, traffic, scenarios = get_artifacts()
    verify_cross_module(sv, matrix, traffic, scenarios)

def test_wrong_tile_id():
    sv, matrix, traffic, scenarios = get_artifacts()
    matrix["pairs"][0]["source_id"] = 99
    with pytest.raises(ValueError, match="Wrong tile ID"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_wrong_coordinate():
    sv, matrix, traffic, scenarios = get_artifacts()
    matrix["pairs"][0]["source_coord"] = {"x": 9, "y": 9}
    with pytest.raises(ValueError, match="Wrong coordinate"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_missing_tile():
    sv, matrix, traffic, scenarios = get_artifacts()
    matrix["pairs"][0]["source"] = "TILE_NONEXISTENT"
    with pytest.raises(ValueError, match="missing in NOC_PKG"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_wrong_route():
    sv, matrix, traffic, scenarios = get_artifacts()
    matrix["pairs"][0]["route"] = ["NORTH", "NORTH", "NORTH"]
    with pytest.raises(ValueError, match="wrong route"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_wrong_hop_count():
    sv, matrix, traffic, scenarios = get_artifacts()
    matrix["pairs"][0]["hop_count"] = 99
    with pytest.raises(ValueError, match="wrong hop count"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_wrong_message_type():
    sv, matrix, traffic, scenarios = get_artifacts()
    traffic["traffic"][0]["msg_type"] = "MSG_INVALID"
    with pytest.raises(ValueError, match="wrong message type"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_wrong_vc():
    sv, matrix, traffic, scenarios = get_artifacts()
    traffic["traffic"][0]["vc_id"] = 99
    with pytest.raises(ValueError, match="wrong VC"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_wrong_length():
    sv, matrix, traffic, scenarios = get_artifacts()
    traffic["traffic"][0]["payload"].append("0xBAD")
    with pytest.raises(ValueError, match="wrong length"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_duplicate_transaction():
    sv, matrix, traffic, scenarios = get_artifacts()
    traffic["traffic"].append(traffic["traffic"][0])
    with pytest.raises(ValueError, match="duplicate transaction"):
        verify_cross_module(sv, matrix, traffic, scenarios)

def test_wrong_response_source():
    sv, matrix, traffic, scenarios = get_artifacts()
    for s in scenarios["scenarios"]:
        if "expected_response" in s:
            s["expected_response"]["source"] = "TILE_NONEXISTENT"
            with pytest.raises(ValueError, match="wrong response source"):
                verify_cross_module(sv, matrix, traffic, scenarios)
            break

def test_wrong_response_destination():
    sv, matrix, traffic, scenarios = get_artifacts()
    for s in scenarios["scenarios"]:
        if "expected_response" in s:
            s["expected_response"]["destination"] = "TILE_NONEXISTENT"
            with pytest.raises(ValueError, match="wrong response destination"):
                verify_cross_module(sv, matrix, traffic, scenarios)
            break

def test_wrong_transaction_id():
    sv, matrix, traffic, scenarios = get_artifacts()
    for s in scenarios["scenarios"]:
        if "expected_response" in s:
            s["expected_response"]["transaction_id"] = "T9999"
            with pytest.raises(ValueError, match="wrong transaction ID"):
                verify_cross_module(sv, matrix, traffic, scenarios)
            break

def test_missing_response():
    sv, matrix, traffic, scenarios = get_artifacts()
    for s in scenarios["scenarios"]:
        if s["scenario_type"] == "MEMORY_READ":
            del s["expected_response"]
            with pytest.raises(ValueError, match="missing response"):
                verify_cross_module(sv, matrix, traffic, scenarios)
            break

def test_duplicate_response():
    sv, matrix, traffic, scenarios = get_artifacts()
    for s in scenarios["scenarios"]:
        if s["scenario_type"] == "ATTESTATION_CHALLENGE":
            s["expected_response"] = {}
            with pytest.raises(ValueError, match="duplicate response"):
                verify_cross_module(sv, matrix, traffic, scenarios)
            break
