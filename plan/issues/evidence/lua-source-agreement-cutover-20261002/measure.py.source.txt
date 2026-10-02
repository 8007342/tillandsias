#!/usr/bin/env python3
"""Read-only source audit; all generated files stay beside this harness.
Run: python3 /absolute/path/to/measure.py
Snapshots plan-debug/plan-release must already exist here. Source blobs are
cached on first execution, so subsequent executions use retained immutable data.
No builds, git writes, user data, or shell-command strings are executed.
"""
import base64
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time
import yaml

BASE = Path(__file__).resolve().parent
WORKER = Path('/home/tlatoani/codex/tillandsias-lua-work/1484-uf29')
REF = 'e6e5e0e64'
FIELDS = {
    'tray_process_naming': ['source'],
    'dev_embed_model_agreement': ['hook', 'ensure'],
    'inference_container_name_agreement': ['script', 'probe'],
}
GUARDS = {
    'tray_process_naming': 'scripts/check-tray-process-running-naming.sh',
    'dev_embed_model_agreement': 'scripts/check-dev-embed-model-agreement.sh',
    'inference_container_name_agreement': 'scripts/check-inference-container-name-agreement.sh',
}
CANONICAL = {
    'source': 'crates/tillandsias-macos-tray/src/diagnose.rs',
    'hook': 'images/default/config-overlay/mcp/lib-dev-env.sh',
    'ensure': 'scripts/dev-inference-ensure.sh',
}
ENV = {'PATH': '/usr/bin:/bin', 'HOME': str(BASE), 'TMPDIR': str(BASE),
       'LC_ALL': 'C', 'LANG': 'C', 'TZ': 'UTC', 'GIT_TERMINAL_PROMPT': '0'}

def digest(b):
    return hashlib.sha256(b).hexdigest()

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)

def blob(ref, path, optional=False):
    target = BASE / 'blobs' / ref / path
    absent = target.with_name(target.name + '.ABSENT')
    if target.exists():
        return target.read_bytes()
    if absent.exists():
        return None
    r = subprocess.run(['git', 'show', ref + ':' + path], cwd=WORKER,
                       capture_output=True)
    if r.returncode:
        if not optional:
            raise RuntimeError(r.stderr.decode())
        write(absent, r.stderr)
        return None
    write(target, r.stdout)
    return r.stdout

def command(case, profile):
    root = Path(case['root'])
    env = dict(ENV, TILLANDSIAS_REPO_ROOT=str(root))
    if case['operation'] == 'inference_container_name_agreement':
        env['TILLANDSIAS_DEV_INFERENCE_SCRIPT'] = case['args'][0]
        env['TILLANDSIAS_ACCEL_PROBE_SRC'] = case['args'][1]
    if profile == 'old':
        argv = ['/usr/bin/bash', str(root / GUARDS[case['operation']])]
    else:
        argv = [str(BASE / ('plan-' + profile)), 'script', 'run',
                str(BASE / 'source-agreements.lua'), '--', case['operation'],
                *case['args']]
    return argv, env

def run(case, profile):
    argv, env = command(case, profile)
    started = time.perf_counter_ns()
    r = subprocess.run(argv, cwd=case['root'], env=env, capture_output=True,
                       timeout=15)
    elapsed = time.perf_counter_ns() - started
    return {'case': case['id'], 'profile': profile, 'argv': argv,
            'cwd': case['root'], 'elapsed_ns': elapsed, 'exit': r.returncode,
            'stdout_b64': base64.b64encode(r.stdout).decode(),
            'stderr_b64': base64.b64encode(r.stderr).decode(),
            'stdout_sha256': digest(r.stdout), 'stderr_sha256': digest(r.stderr)}

def same(a, b):
    return all(a[k] == b[k] for k in ['exit', 'stdout_b64', 'stderr_b64'])

def bundle(cases, profile):
    started = time.perf_counter_ns()
    runs = [run(case, profile) for case in cases]
    return {'profile': profile, 'elapsed_ns': time.perf_counter_ns() - started,
            'runs': runs}

def stats(samples):
    ordered = sorted(samples)
    return {'n': len(samples), 'median_ns': statistics.median(samples),
            'p95_ns': ordered[math.ceil(.95 * len(samples)) - 1],
            'min_ns': min(samples), 'max_ns': max(samples)}

def main():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    out = BASE / ('run-' + stamp)
    out.mkdir()
    manifest_bytes = blob(REF, 'scripts/fixtures/source-agreements.yaml')
    manifest = yaml.safe_load(manifest_bytes)
    assert len(manifest['cases']) == 13
    write(BASE / 'source-agreements.lua', blob(REF, 'scripts/lua/source-agreements.lua'))
    cases = []
    for entry in manifest['cases']:
        root = out / 'case roots' / entry['id']
        (root / '.git').mkdir(parents=True)
        write(root / 'plan/index.yaml', b'packets: []\n')
        op = entry['operation']
        write(root / GUARDS[op], blob(REF + '^', GUARDS[op]))
        args, inputs = [], []
        for field in FIELDS[op]:
            original = entry[field]
            data = blob(REF, original, optional=entry['id'] == 'inference-missing-file')
            relative = CANONICAL[field] if field in CANONICAL else original
            # Old tray reads a relative canonical spelling; old dev uses absolute
            # canonical paths. Inference overrides accept the same relative paths.
            spelling = str(root / relative) if field in ['hook', 'ensure'] else relative
            args.append(spelling)
            if data is not None:
                write(root / relative, data)
            inputs.append({'field': field, 'immutable_source': REF + ':' + original,
                           'path': spelling, 'exists': data is not None,
                           'bytes': len(data) if data is not None else 0,
                           'sha256': digest(data) if data is not None else None,
                           'crlf_count': data.count(b'\r\n') if data is not None else 0})
        cases.append({'id': entry['id'], 'operation': op, 'root': str(root),
                      'args': args, 'inputs': inputs})
    live = [next(c for c in cases if c['id'] == n)
            for n in ['tray-live', 'dev-model-live', 'inference-live']]
    # This is the first guard execution using these snapshots in this harness.
    # File/page caches are not purged: it is emphatically NOT OS-cold.
    first_launch = [bundle(live, p) for p in ['old', 'debug', 'release']]
    identities = {}
    for profile in ['debug', 'release']:
        exe = BASE / ('plan-' + profile)
        r = subprocess.run([str(exe), 'build-id'], cwd=live[0]['root'],
                           env=dict(ENV, TILLANDSIAS_REPO_ROOT=live[0]['root']),
                           capture_output=True, timeout=15)
        identities[profile] = {'snapshot': str(exe), 'sha256': digest(exe.read_bytes()),
                               'bytes': exe.stat().st_size, 'build_id_exit': r.returncode,
                               'build_id': r.stdout.decode(), 'stderr': r.stderr.decode()}
    parity = []
    for case in cases:
        old = run(case, 'old')
        profiles = {p: run(case, p) for p in ['debug', 'release']}
        parity.append({'case': case['id'], 'old': old, 'new': profiles,
                       'equal': {p: same(old, new) for p, new in profiles.items()}})
    # Explicit space-bearing file ARGUMENT, in addition to all roots having spaces.
    crlf = dict(next(c for c in cases if c['id'] == 'tray-crlf-space-path'))
    crlf['args'] = [str(Path(crlf['root']) / crlf['args'][0])]
    supplemental = {'label': 'CRLF with absolute space-bearing Lua file argument',
                    'old': run(crlf, 'old'),
                    'new': {p: run(crlf, p) for p in ['debug', 'release']}}
    supplemental['equal'] = {p: same(supplemental['old'], r)
                             for p, r in supplemental['new'].items()}
    profiles = {}
    for profile in ['debug', 'release']:
        warmup = [bundle(live, p) for p in ['old', profile]]
        rounds = []
        for i in range(30):
            order = ['old', profile] if i % 2 == 0 else [profile, 'old']
            runs = {p: bundle(live, p) for p in order}
            rounds.append({'round': i + 1, 'order': order, 'bundles': runs,
                           'byte_parity': all(same(a, b) for a, b in
                               zip(runs['old']['runs'], runs[profile]['runs']))})
        old_stats = stats([r['bundles']['old']['elapsed_ns'] for r in rounds])
        new_stats = stats([r['bundles'][profile]['elapsed_ns'] for r in rounds])
        profiles[profile] = {'warmup': warmup, 'rounds': rounds,
                             'old': old_stats, 'new': new_stats,
                             'p95_ratio': new_stats['p95_ns'] / old_stats['p95_ns'],
                             'within_110_percent': new_stats['p95_ns'] <= 1.10 * old_stats['p95_ns']}
    provenance = {
        'utc': stamp, 'immutable_lua_ref': REF, 'old_guard_ref': REF + '^',
        'source_worktree_read_only': str(WORKER),
        'debug_copied_from': str(WORKER / 'target/debug/tillandsias-plan'),
        'release_copied_from': '/home/tlatoani/codex/tillandsias-opencode-lua-session-20261002/target/release/tillandsias-plan',
        'identities': identities, 'lua_sha256': digest((BASE / 'source-agreements.lua').read_bytes()),
        'manifest_sha256': digest(manifest_bytes), 'harness_sha256': digest(Path(__file__).read_bytes()),
        'environment': ENV, 'timing_clock': 'time.perf_counter_ns',
        'median': 'arithmetic mean of sorted samples 15 and 16 (n=30)',
        'p95': 'nearest rank ceil(0.95*n): sorted sample 29 of 30',
        'first_launch': 'first three-decision bundle for each profile; NOT OS-cold; no cache eviction',
        'measurement_scope': 'three sequential fresh-process live decisions; bundle includes Python subprocess/capture bookkeeping; excludes fixture setup, source retrieval and hashing binaries',
        'load': 'parent full gate may run concurrently; sequential debug/release blocks, each independently paired against Bash',
        'process_count': {'strace': shutil.which('strace'), 'observed': False,
                          'reason': 'strace unavailable; no tools installed; descendants not traced',
                          'explicit_harness_launches_per_bundle': 3,
                          'old_total_estimate': 17,
                          'old_total_estimate_source': 'prior Terra static estimate, not remeasured',
                          'lua_evaluator_children_estimate': 0,
                          'lua_evaluator_estimate_basis': 'cacheable evaluator architecture, NOT observed process count'},
        'input_accounting': {'scope': 'sum of five explicit live source lengths per three-decision bundle; ensure counted separately in dev and inference; logical declared bytes, not observed syscalls',
                             'bytes': sum(i['bytes'] for c in live for i in c['inputs']),
                             'excludes': 'Lua module, old guard scripts, manifest (not read by production CLI), executable/shared libraries and sandbox filesystem metadata'},
    }
    # Source identities are Git object queries, not mutations; retained for audit.
    provenance['git_objects'] = {name: subprocess.check_output(['git', 'rev-parse', name], cwd=WORKER, text=True).strip()
                                 for name in [REF, REF+'^', REF+':scripts/lua/source-agreements.lua']}
    receipts = {'provenance': provenance, 'cases': cases, 'first_launch': first_launch,
                'parity': parity, 'supplemental': supplemental, 'profiles': profiles}
    raw = (json.dumps(receipts, indent=2) + '\n').encode()
    write(out / 'receipts.json', raw)
    summary = {'receipt': str(out / 'receipts.json'), 'receipt_sha256': digest(raw),
               'identities': identities, 'lua_sha256': provenance['lua_sha256'],
               'input_bytes': provenance['input_accounting']['bytes'],
               'parity': {p: {'equal': sum(x['equal'][p] for x in parity), 'total': len(parity),
                              'mismatches': [x['case'] for x in parity if not x['equal'][p]]}
                          for p in ['debug', 'release']},
               'supplemental': supplemental['equal'],
               'first_launch_ms': {b['profile']: b['elapsed_ns']/1e6 for b in first_launch},
               'profiles': {p: {k: v for k,v in r.items() if k not in ['rounds','warmup']} for p,r in profiles.items()},
               'all_warm_rounds_byte_equal': {p: all(r['byte_parity'] for r in x['rounds']) for p,x in profiles.items()}}
    write(out / 'summary.json', (json.dumps(summary, indent=2)+'\n').encode())
    print(json.dumps(summary, indent=2))

if __name__ == '__main__':
    main()
