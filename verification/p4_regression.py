import argparse
import json
import subprocess
import sys
from pathlib import Path
from verification.verify_tile_map import parse_tile_enum, parse_tile_coordinates
from verification.xy_route_oracle import route, Coord, Direction
from verification.sv_vector_bridge import MESSAGE_PAYLOAD_FLITS, MESSAGE_VC

MSG_TYPES = {
    "MSG_MEM_RD_REQ": 0,
    "MSG_MEM_RD_RESP": 1,
    "MSG_MEM_WR_REQ": 2,
    "MSG_MEM_WR_RESP": 3,
    "MSG_ATTEST_CHALLENGE": 4,
    "MSG_ATTEST_RESPONSE": 5,
    "MSG_ATTEST_GRANT": 6,
    "MSG_ATTEST_REVOKE": 7,
}

VC_NAMES = {
    0: "VC_REQUEST",
    1: "VC_RESPONSE",
    2: "VC_ATTESTATION",
}

def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))

def verify_cross_module(sv_file, pair_matrix, traffic_vectors, integration_scenarios):
    text = Path(sv_file).read_text(encoding="utf-8")
    enums = parse_tile_enum(text)
    coords = parse_tile_coordinates(text)
    
    valid_tiles = {}
    for name, id_ in enums.items():
        if name in coords:
            valid_tiles[name] = {"id": id_, "coord": {"x": coords[name][0], "y": coords[name][1]}}
            
    # Matrix Check
    for pair in pair_matrix.get("pairs", []):
        src = pair["source"]
        dst = pair["destination"]
        if src not in valid_tiles:
            raise ValueError(f"missing in NOC_PKG")
        if dst not in valid_tiles:
            raise ValueError(f"missing in NOC_PKG")
        if pair["source_id"] != valid_tiles[src]["id"]:
            raise ValueError(f"Wrong tile ID")
        if pair["destination_id"] != valid_tiles[dst]["id"]:
            raise ValueError(f"Wrong tile ID")
        if pair["source_coord"] != valid_tiles[src]["coord"]:
            raise ValueError(f"Wrong coordinate")
        if pair["destination_coord"] != valid_tiles[dst]["coord"]:
            raise ValueError(f"Wrong coordinate")
            
        src_c = Coord(pair["source_coord"]["x"], pair["source_coord"]["y"])
        dst_c = Coord(pair["destination_coord"]["x"], pair["destination_coord"]["y"])
        expected_route = [d.name for d in route(src_c, dst_c)]
        expected_hop = len(expected_route) if expected_route != ["LOCAL"] else 0
        
        if pair["route"] != expected_route:
            raise ValueError("wrong route")
        if pair["hop_count"] != expected_hop:
            raise ValueError("wrong hop count")
            
    # Traffic Vectors Check
    tx_ids = set()
    for t in traffic_vectors.get("traffic", []):
        if t["transaction_id"] in tx_ids:
            raise ValueError("duplicate transaction")
        tx_ids.add(t["transaction_id"])
        
        src = t["source"]
        dst = t["destination"]
        if src not in valid_tiles or dst not in valid_tiles:
            raise ValueError(f"missing in NOC_PKG")
        if t["source_coord"] != valid_tiles[src]["coord"] or t["destination_coord"] != valid_tiles[dst]["coord"]:
            raise ValueError(f"wrong coordinate")
            
        src_c = Coord(t["source_coord"]["x"], t["source_coord"]["y"])
        dst_c = Coord(t["destination_coord"]["x"], t["destination_coord"]["y"])
        expected_route = [d.name for d in route(src_c, dst_c)]
        expected_hop = len(expected_route) if expected_route != ["LOCAL"] else 0
        if t["route"] != expected_route:
            raise ValueError("wrong route")
        if t["hop_count"] != expected_hop:
            raise ValueError("wrong hop count")
            
        if t["msg_type"] not in MSG_TYPES:
            raise ValueError("wrong message type")
            
        msg_id = MSG_TYPES[t["msg_type"]]
        expected_vc = MESSAGE_VC[msg_id]
        if t["vc"] != VC_NAMES[expected_vc] or t["vc_id"] != expected_vc:
            raise ValueError("wrong VC")
            
        expected_payload = MESSAGE_PAYLOAD_FLITS[msg_id]
        if len(t["payload"]) != expected_payload:
            raise ValueError("wrong length")
            
    # Scenarios Check
    for s in integration_scenarios.get("scenarios", []):
        req = s["request"]
        src = req["source"]
        dst = req["destination"]
        if src not in valid_tiles or dst not in valid_tiles:
            raise ValueError("missing in NOC_PKG")
        
        src_c = Coord(req["source_coord"]["x"], req["source_coord"]["y"])
        dst_c = Coord(req["destination_coord"]["x"], req["destination_coord"]["y"])
        expected_route = [d.name for d in route(src_c, dst_c)]
        expected_hop = len(expected_route) if expected_route != ["LOCAL"] else 0
        if req["route"] != expected_route:
            raise ValueError("wrong request route")
        if req["hop_count"] != expected_hop:
            raise ValueError("wrong hop count")
            
        msg_id = MSG_TYPES[req["msg_type"]]
        expected_vc = MESSAGE_VC[msg_id]
        if req["vc_id"] != expected_vc:
            raise ValueError("wrong VC")
        if len(req["payload"]) != MESSAGE_PAYLOAD_FLITS[msg_id]:
            raise ValueError("wrong length")
            
        if s["scenario_type"] in ["MEMORY_READ", "MEMORY_WRITE"]:
            if "expected_response" not in s:
                raise ValueError("missing response")
            resp = s["expected_response"]
            if resp["source"] != dst:
                raise ValueError("wrong response source")
            if resp["destination"] != src:
                raise ValueError("wrong response destination")
                
            expected_route = [d.name for d in route(dst_c, src_c)]
            expected_hop = len(expected_route) if expected_route != ["LOCAL"] else 0
            if resp["route"] != expected_route:
                raise ValueError("wrong response route")
            if resp["hop_count"] != expected_hop:
                raise ValueError("wrong response hop count")
                
            resp_msg_id = MSG_TYPES[resp["msg_type"]]
            expected_resp_vc = MESSAGE_VC[resp_msg_id]
            if resp["vc_id"] != expected_resp_vc:
                raise ValueError("wrong VC")
            if len(resp["payload"]) != MESSAGE_PAYLOAD_FLITS[resp_msg_id]:
                raise ValueError("wrong length")
                
            if resp["transaction_id"] != req["transaction_id"]:
                raise ValueError("wrong transaction ID")
        else:
            if "expected_response" in s:
                raise ValueError("duplicate response")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sv", type=Path, default=Path("NOC_PQATTEST.srcs/sources_1/new/NOC_PKG.sv"))
    parser.add_argument("--matrix", type=Path, default=Path("software/noc_pair_matrix.json"))
    parser.add_argument("--traffic", type=Path, default=Path("software/noc_traffic_vectors.json"))
    parser.add_argument("--scenarios", type=Path, default=Path("software/integration_scenarios.json"))
    parser.add_argument("--run-tests", action="store_true", help="Run full pytest regression")
    args = parser.parse_args()
    
    pair_matrix = load_json(args.matrix)
    traffic_vectors = load_json(args.traffic)
    scenarios = load_json(args.scenarios)
    
    verify_cross_module(args.sv, pair_matrix, traffic_vectors, scenarios)
    print("Cross-module consistency: PASS")
    
    if args.run_tests:
        print("Running full fault-injection regression...")
        result = subprocess.run([sys.executable, "-m", "pytest", "verification", "-v"])
        if result.returncode != 0:
            print("Fault-injection regression: FAIL")
            return 1
        else:
            print("Fault-injection regression: PASS")
            
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
