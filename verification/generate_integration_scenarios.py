import argparse
import json
from pathlib import Path
from verification.xy_route_oracle import route, Coord, Direction
from verification.sv_vector_bridge import (
    MESSAGE_PAYLOAD_FLITS,
    MESSAGE_VC,
)

MSG_NAMES = {
    0: "MSG_MEM_RD_REQ",
    1: "MSG_MEM_RD_RESP",
    2: "MSG_MEM_WR_REQ",
    3: "MSG_MEM_WR_RESP",
    4: "MSG_ATTEST_CHALLENGE",
    5: "MSG_ATTEST_RESPONSE",
    6: "MSG_ATTEST_GRANT",
    7: "MSG_ATTEST_REVOKE",
}

VC_NAMES = {
    0: "VC_REQUEST",
    1: "VC_RESPONSE",
    2: "VC_ATTESTATION",
}

def get_msg_id(name: str) -> int:
    for k, v in MSG_NAMES.items():
        if v == name:
            return k
    raise ValueError(f"Unknown message type {name}")

def generate_payload(msg_type_id: int, seed: int) -> list[str]:
    count = MESSAGE_PAYLOAD_FLITS[msg_type_id]
    payload = []
    for i in range(count):
        val = ((seed & 0xFFFF) << 16) | (msg_type_id << 8) | (i + 1)
        payload.append(f"0x{val:08X}")
    return payload

def build_packet(tx_id: str, src: dict, dst: dict, msg_name: str, seed: int) -> dict:
    msg_id = get_msg_id(msg_name)
    vc_id = MESSAGE_VC[msg_id]
    
    src_coord = Coord(src["coord"]["x"], src["coord"]["y"])
    dst_coord = Coord(dst["coord"]["x"], dst["coord"]["y"])
    
    rt = [d.name for d in route(src_coord, dst_coord)]
    
    return {
        "transaction_id": tx_id,
        "source": src["name"],
        "source_id": src["id"],
        "source_coord": src["coord"],
        "destination": dst["name"],
        "destination_id": dst["id"],
        "destination_coord": dst["coord"],
        "msg_type": msg_name,
        "msg_type_id": msg_id,
        "vc": VC_NAMES[vc_id],
        "vc_id": vc_id,
        "route": rt,
        "hop_count": len(rt) if rt != ["LOCAL"] else 0,
        "payload": generate_payload(msg_id, seed)
    }

def generate_scenarios(pairs: list[dict]) -> list[dict]:
    scenarios = []
    scenario_types = [
        ("MEMORY_READ", "MSG_MEM_RD_REQ", "MSG_MEM_RD_RESP"),
        ("MEMORY_WRITE", "MSG_MEM_WR_REQ", "MSG_MEM_WR_RESP"),
        ("ATTESTATION_CHALLENGE", "MSG_ATTEST_CHALLENGE", None),
        ("ATTESTATION_RESPONSE", "MSG_ATTEST_RESPONSE", None),
        ("ATTESTATION_GRANT", "MSG_ATTEST_GRANT", None),
        ("ATTESTATION_REVOKE", "MSG_ATTEST_REVOKE", None),
    ]
    
    for i, pair in enumerate(pairs):
        stype, req_msg, resp_msg = scenario_types[i % len(scenario_types)]
        
        scenario_id = f"S{i+1:04d}"
        tx_id = f"T{i+1:04d}"
        seed = (pair["source_id"] << 8) | pair["destination_id"]
        
        src_info = {
            "name": pair["source"],
            "id": pair["source_id"],
            "coord": pair["source_coord"]
        }
        dst_info = {
            "name": pair["destination"],
            "id": pair["destination_id"],
            "coord": pair["destination_coord"]
        }
        
        req = build_packet(tx_id, src_info, dst_info, req_msg, seed)
        
        scenario = {
            "scenario_id": scenario_id,
            "scenario_type": stype,
            "request": req,
        }
        
        if resp_msg:
            resp = build_packet(tx_id, dst_info, src_info, resp_msg, seed ^ 0xFFFF)
            scenario["expected_response"] = resp
            
        scenarios.append(scenario)
        
    return scenarios

def verify_scenarios(scenarios: list[dict], original_pairs: list[dict] = None):
    if not scenarios:
        raise ValueError("missing scenario")

    valid_sources = set()
    valid_destinations = set()
    if original_pairs:
        for p in original_pairs:
            valid_sources.add(p["source"])
            valid_destinations.add(p["destination"])
            
    tx_ids = set()
    for s in scenarios:
        req = s["request"]
        
        if req["transaction_id"] in tx_ids:
            raise ValueError("duplicate transaction ID")
        tx_ids.add(req["transaction_id"])
        
        if original_pairs:
            if req["source"] not in valid_sources:
                raise ValueError("wrong request source")
            if req["destination"] not in valid_destinations:
                raise ValueError("wrong request destination")
                
        r_coord = Coord(req["source_coord"]["x"], req["source_coord"]["y"])
        d_coord = Coord(req["destination_coord"]["x"], req["destination_coord"]["y"])
        rt = [d.name for d in route(r_coord, d_coord)]
        expected_hop = len(rt) if rt != ["LOCAL"] else 0
        if req["route"] != rt:
            raise ValueError("wrong request route")
        if req["hop_count"] != expected_hop:
            raise ValueError("wrong request hop count")
            
        msg_id = req["msg_type_id"]
        if req["vc_id"] != MESSAGE_VC[msg_id]:
            raise ValueError("wrong VC")
        if len(req["payload"]) != MESSAGE_PAYLOAD_FLITS[msg_id]:
            raise ValueError("wrong payload count")
            
        stype = s["scenario_type"]
        if stype in ["MEMORY_READ", "MEMORY_WRITE"]:
            if "expected_response" not in s:
                raise ValueError("missing response")
            resp = s["expected_response"]
            
            if resp["source"] != req["destination"]:
                raise ValueError("wrong response source")
            if resp["destination"] != req["source"]:
                raise ValueError("wrong response destination")
                
            resp_msg_id = resp["msg_type_id"]
            if resp["vc_id"] != MESSAGE_VC[resp_msg_id]:
                raise ValueError("wrong VC")
            if len(resp["payload"]) != MESSAGE_PAYLOAD_FLITS[resp_msg_id]:
                raise ValueError("wrong payload count")
                
            if resp["transaction_id"] != req["transaction_id"]:
                raise ValueError("wrong transaction ID")
                
            rt_resp = [d.name for d in route(d_coord, r_coord)]
            expected_hop_resp = len(rt_resp) if rt_resp != ["LOCAL"] else 0
            if resp["route"] != rt_resp:
                raise ValueError("wrong response route")
            if resp["hop_count"] != expected_hop_resp:
                raise ValueError("wrong response hop count")
                
            if stype == "MEMORY_READ" and resp["msg_type"] != "MSG_MEM_RD_RESP":
                raise ValueError("wrong response type")
            if stype == "MEMORY_WRITE" and resp["msg_type"] != "MSG_MEM_WR_RESP":
                raise ValueError("wrong response type")
        else:
            if "expected_response" in s:
                raise ValueError("duplicate response")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, default=Path("software/noc_pair_matrix.json"))
    parser.add_argument("--output", type=Path, default=Path("software/integration_scenarios.json"))
    args = parser.parse_args()

    matrix_data = json.loads(args.matrix.read_text(encoding="utf-8"))
    pairs = matrix_data.get("pairs", [])
    
    scenarios = generate_scenarios(pairs)
    verify_scenarios(scenarios, pairs)

    output_data = {"scenarios": scenarios}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output_data, indent=2), encoding="utf-8")
    
    print(f"Generated {len(scenarios)} integration scenarios.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
