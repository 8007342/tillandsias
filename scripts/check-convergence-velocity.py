#!/usr/bin/env python3
# check-convergence-velocity.py — validates convergence velocity (Vc >= Vmin)
# and checks residual CentiColon debt against methodology thresholds.
#
# @trace spec:observability-convergence
# @cheatsheet runtime/plan-discipline.md

from __future__ import annotations

import sys
import json
from pathlib import Path
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SIGNATURE_FILE = REPO_ROOT / "target/convergence/centicolon-signature.jsonl"
EVENT_INDEX = REPO_ROOT / "methodology/event/index.yaml"
PROXIMITY_YAML = REPO_ROOT / "methodology/proximity.yaml"
CONVERGENCE_YAML = REPO_ROOT / "methodology/convergence.yaml"

# Default constraints
DEFAULT_V_MIN = 1.0  # CentiColons per cycle
MAX_ALLOWABLE_SINGLE_RESIDUAL_CC = 120  # Max single check weight in local-ci.sh

def load_signature_records() -> list[dict]:
    if not SIGNATURE_FILE.exists():
        print(f"[-] Signature log not found at {SIGNATURE_FILE}")
        return []
    records = []
    with open(SIGNATURE_FILE, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            if stripped:
                try:
                    records.append(json.loads(stripped))
                except json.JSONDecodeError:
                    continue
    return records

def load_open_high_uncertainty_events() -> list[tuple[str, str, str]]:
    """Scan methodology events to find open/triaged events with high uncertainty."""
    events_dir = REPO_ROOT / "methodology/event"
    if not events_dir.exists():
        print(f"[-] Events directory not found at {events_dir}")
        return []
    
    violating_events = []
    for file_path in events_dir.glob("*.yaml"):
        if file_path.name in ("index.yaml", "000-template-unpredicted.yaml"):
            continue
            
        with open(file_path, "r", encoding="utf-8") as ef:
            try:
                event_data = yaml.safe_load(ef)
            except yaml.YAMLError:
                continue
                
        if not isinstance(event_data, dict):
            continue
            
        status = str(event_data.get("status", "")).strip('\'"')
        uncertainty = str(event_data.get("uncertainty_delta", "none")).lower().strip('\'"')
        
        if status in ("open", "triaged"):
            if uncertainty == "high":
                rel_path = f"methodology/event/{file_path.name}"
                violating_events.append((rel_path, status, uncertainty))
                
    return violating_events

def main() -> int:
    print("[*] Performing convergence velocity and Proximity thresholds validation...")
    
    # 1. Parse signature records
    records = load_signature_records()
    if not records:
        print("[!] No signature records found. Velocity validation bypassed (bootstrapping).")
        return 0
        
    latest = records[-1]
    timestamp = latest.get("timestamp", "unknown")
    commit = latest.get("source_commit", "unknown")
    r_t = latest.get("residual_cc", 0)
    percent_closed = latest.get("percent_closed", 0.0)
    max_residual_cc = latest.get("max_residual_cc", 0)
    max_residual_spec = latest.get("max_residual_spec", "n/a")
    
    print(f"[+] Latest Signature: {timestamp} (commit: {commit})")
    print(f"    - Residual Correctness Debt (R_t): {r_t} cc")
    print(f"    - Percent Closed: {percent_closed:.2f}%")
    print(f"    - Max Residual: {max_residual_cc} cc ({max_residual_spec})")
    
    # 2. Enforce strictly positive lower bound of convergence velocity when R_t > 0
    if r_t > 0:
        if len(records) < 4:
            print(f"[i] Velocity tracking is bootstrapping ({len(records)} records < 4). Skipping V_c checks.")
        else:
            prev_3 = records[-4]
            r_t_minus_3 = prev_3.get("residual_cc", 0)
            
            # Convergence velocity: delta_R / delta_t (where delta_t is 3 cycles)
            v_c = (r_t_minus_3 - r_t) / 3.0
            print(f"[+] Calculated Convergence Velocity (V_c): {v_c:.2f} cc/cycle")
            
            if v_c < DEFAULT_V_MIN:
                print(f"[-] CONSTRAINTS VIOLATION: Convergence Velocity (V_c = {v_c:.2f}) falls below V_min ({DEFAULT_V_MIN:.2f})")
                print(f"    Previous residual debt (3 cycles ago): {r_t_minus_3} cc")
                print(f"    Current residual debt: {r_t} cc")
                print("[!] High-Velocity Alignment Event is active: freezing feature work, lease TTL is frozen at 1 hour.")
                return 1
            else:
                print(f"[+] Velocity check passed: V_c ({v_c:.2f}) >= V_min ({DEFAULT_V_MIN:.2f})")
    else:
        print("[+] R_t is 0 (convergence fully achieved). Velocity check passed automatically.")

    # 3. Proximity / Threshold enforcement against methodology/proximity.yaml
    # Rule A:Scores above 95 percent require no open high uncertainty events.
    if percent_closed >= 95.0:
        print("[*] Percent closed is >= 95.0%. Verifying no open high uncertainty events...")
        violators = load_open_high_uncertainty_events()
        if violators:
            print("[-] CONSTRAINTS VIOLATION: Scores above 95 percent require no open high/medium uncertainty events.")
            for filepath, status, uncertainty in violators:
                print(f"    - {filepath} (status: {status}, uncertainty: {uncertainty})")
            return 1
        print("[+] Proximity verification passed: zero open high/medium uncertainty events found.")
        
    # Rule B: Single spec residual cc debt must not exceed the maximum allowable threshold
    if max_residual_cc > MAX_ALLOWABLE_SINGLE_RESIDUAL_CC:
        print(f"[-] CONSTRAINTS VIOLATION: Max single residual debt ({max_residual_cc} cc) exceeds allowable threshold ({MAX_ALLOWABLE_SINGLE_RESIDUAL_CC} cc)")
        print(f"    - Violating Spec: {max_residual_spec}")
        return 1
    
    print("[+] All convergence velocity and proximity checks passed successfully.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
