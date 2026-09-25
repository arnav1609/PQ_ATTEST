import pytest
import json
import copy
from pathlib import Path
from verification.generate_integration_scenarios import generate_scenarios, verify_scenarios

def get_pairs():
    path = Path("software/noc_pair_matrix.json")
    if not path.exists():
        return []
    return json.loads(path.read_text())["pairs"]

def test_correct_scenarios_generate():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    verify_scenarios(scenarios, pairs)

def test_output_deterministic():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    s1 = generate_scenarios(pairs)
    s2 = generate_scenarios(pairs)
    assert s1 == s2

def test_all_required_scenario_types_exist():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    types_found = {s["scenario_type"] for s in scenarios}
    expected = {
        "MEMORY_READ", "MEMORY_WRITE", 
        "ATTESTATION_CHALLENGE", "ATTESTATION_RESPONSE", 
        "ATTESTATION_GRANT", "ATTESTATION_REVOKE"
    }
    assert expected.issubset(types_found)

def test_wrong_request_source():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    scenarios[0]["request"]["source"] = "INVALID"
    with pytest.raises(ValueError, match="wrong request source"):
        verify_scenarios(scenarios, pairs)

def test_wrong_request_destination():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    scenarios[0]["request"]["destination"] = "INVALID"
    with pytest.raises(ValueError, match="wrong request destination"):
        verify_scenarios(scenarios, pairs)

def test_wrong_request_route():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    scenarios[0]["request"]["route"] = ["NORTH", "NORTH", "NORTH", "NORTH", "NORTH"]
    with pytest.raises(ValueError, match="wrong request route"):
        verify_scenarios(scenarios, pairs)

def test_wrong_request_hop_count():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    scenarios[0]["request"]["hop_count"] = 99
    with pytest.raises(ValueError, match="wrong request hop count"):
        verify_scenarios(scenarios, pairs)

def test_wrong_response_source():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    # Find a scenario with a response
    for s in scenarios:
        if "expected_response" in s:
            s["expected_response"]["source"] = "INVALID"
            with pytest.raises(ValueError, match="wrong response source"):
                verify_scenarios(scenarios, pairs)
            break

def test_wrong_response_destination():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    for s in scenarios:
        if "expected_response" in s:
            s["expected_response"]["destination"] = "INVALID"
            with pytest.raises(ValueError, match="wrong response destination"):
                verify_scenarios(scenarios, pairs)
            break

def test_wrong_response_route():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    for s in scenarios:
        if "expected_response" in s:
            s["expected_response"]["route"] = ["NORTH", "NORTH", "NORTH", "NORTH", "NORTH"]
            with pytest.raises(ValueError, match="wrong response route"):
                verify_scenarios(scenarios, pairs)
            break

def test_wrong_response_hop_count():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    for s in scenarios:
        if "expected_response" in s:
            s["expected_response"]["hop_count"] = 99
            with pytest.raises(ValueError, match="wrong response hop count"):
                verify_scenarios(scenarios, pairs)
            break

def test_wrong_response_type():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    for s in scenarios:
        if "expected_response" in s:
            s["expected_response"]["msg_type"] = "MSG_INVALID"
            with pytest.raises(ValueError, match="wrong response type"):
                verify_scenarios(scenarios, pairs)
            break

def test_wrong_vc():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    scenarios[0]["request"]["vc_id"] = 99
    with pytest.raises(ValueError, match="wrong VC"):
        verify_scenarios(scenarios, pairs)

def test_wrong_transaction_id():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    for s in scenarios:
        if "expected_response" in s:
            s["expected_response"]["transaction_id"] = "T9999"
            with pytest.raises(ValueError, match="wrong transaction ID"):
                verify_scenarios(scenarios, pairs)
            break

def test_missing_response():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    for s in scenarios:
        if s["scenario_type"] == "MEMORY_READ":
            del s["expected_response"]
            with pytest.raises(ValueError, match="missing response"):
                verify_scenarios([s], pairs)
            break

def test_duplicate_response():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    for s in scenarios:
        if s["scenario_type"] == "ATTESTATION_CHALLENGE":
            s["expected_response"] = {}
            with pytest.raises(ValueError, match="duplicate response"):
                verify_scenarios([s], pairs)
            break

def test_payload_count_matches():
    pairs = get_pairs()
    if not pairs:
        pytest.skip()
    scenarios = generate_scenarios(pairs)
    scenarios[0]["request"]["payload"].append("0xBAD")
    with pytest.raises(ValueError, match="wrong payload count"):
        verify_scenarios(scenarios, pairs)
