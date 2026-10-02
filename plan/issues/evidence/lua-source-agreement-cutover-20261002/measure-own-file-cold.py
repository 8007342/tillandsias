#!/usr/bin/env python3
"""Own-file page-cold control, never a global drop_caches or OS-cold claim."""
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

WORK = Path('/home/tlatoani/codex/tillandsias-lua-work/1484-uf29')
OUT = Path('/tmp/opencode/lua-implementation-boundary.dOHIiQ/tmp')
BASE = Path(tempfile.mkdtemp(prefix='parent-cold-source-', dir=WORK / 'target'))
REF = 'e6e5e0e64'
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                      ctypes.c_int, ctypes.c_int, ctypes.c_long]
libc.mmap.restype = ctypes.c_void_p
libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
PAGE = os.sysconf('SC_PAGE_SIZE')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def blob(ref, name):
    return subprocess.check_output(['git', 'show', f'{ref}:{name}'], cwd=WORK)

def write(name, data, executable=False):
    p = BASE / name
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open('wb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    if executable:
        p.chmod(0o700)
    return p

def resident(p):
    size = p.stat().st_size
    if not size:
        return {'pages': 0, 'resident': 0}
    with p.open('rb') as f:
        addr = libc.mmap(None, size, 1, 1, f.fileno(), 0)
        if addr == ctypes.c_void_p(-1).value:
            raise OSError(ctypes.get_errno(), 'mmap')
        try:
            n = (size + PAGE - 1) // PAGE
            vec = (ctypes.c_ubyte * n)()
            if libc.mincore(addr, size, vec):
                raise OSError(ctypes.get_errno(), 'mincore')
            return {'pages': n, 'resident': sum(bool(v & 1) for v in vec)}
        finally:
            assert libc.munmap(addr, size) == 0

source_binary = OUT / 'astra-source-parity-1474ljse/plan-release'
exe = write('bin/plan-release', source_binary.read_bytes(), True)
bash = write('bin/bash', Path('/usr/bin/bash').read_bytes(), True)
lua = write('scripts/source-agreements.lua', blob(REF, 'scripts/lua/source-agreements.lua'))
names = [
    'crates/tillandsias-macos-tray/src/diagnose.rs',
    'images/default/config-overlay/mcp/lib-dev-env.sh',
    'scripts/dev-inference-ensure.sh',
    'crates/tillandsias-headless/src/accel_probe.rs',
]
inputs = [write(name, blob(REF, name)) for name in names]
guards = [write(name, blob(REF + '^', name)) for name in [
    'scripts/check-tray-process-running-naming.sh',
    'scripts/check-dev-embed-model-agreement.sh',
    'scripts/check-inference-container-name-agreement.sh',
]]
(BASE / '.git').mkdir()
cases = [
    ('tray_process_naming', [names[0]]),
    ('dev_embed_model_agreement', [str(BASE / names[1]), str(BASE / names[2])]),
    ('inference_container_name_agreement', [names[2], names[3]]),
]
env = {'PATH': '/usr/bin:/bin', 'HOME': str(BASE), 'TMPDIR': str(BASE),
       'LC_ALL': 'C', 'LANG': 'C', 'TZ': 'UTC',
       'TILLANDSIAS_REPO_ROOT': str(BASE), 'GIT_TERMINAL_PROMPT': '0'}
files = [exe, bash, lua, *inputs, *guards]
identities = {str(p.relative_to(BASE)): {'bytes': p.stat().st_size,
                                      'sha256': sha(p.read_bytes())} for p in files}
rounds = []
for i in range(5):
    bundles = {}
    for profile in (['bash', 'lua'] if i % 2 == 0 else ['lua', 'bash']):
        for p in files:
            with p.open('rb') as f:
                os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
        residency = {str(p.relative_to(BASE)): resident(p) for p in files}
        records = []
        start = time.perf_counter_ns()
        for j, (operation, args) in enumerate(cases):
            argv = ([str(bash), str(guards[j])] if profile == 'bash' else
                    [str(exe), 'script', 'run', str(lua), '--', operation, *args])
            child_env = dict(env)
            if j == 2:
                child_env.update(TILLANDSIAS_DEV_INFERENCE_SCRIPT=args[0],
                                 TILLANDSIAS_ACCEL_PROBE_SRC=args[1])
            s = time.perf_counter_ns()
            r = subprocess.run(argv, cwd=BASE, env=child_env, capture_output=True, timeout=15)
            records.append({'argv': argv, 'code': r.returncode,
                            'wall_ns': time.perf_counter_ns() - s,
                            'stdout_b64': base64.b64encode(r.stdout).decode(),
                            'stderr_b64': base64.b64encode(r.stderr).decode()})
        bundles[profile] = {'wall_ns': time.perf_counter_ns() - start,
                            'before_residency': residency, 'runs': records}
    parity = all((a['code'], a['stdout_b64'], a['stderr_b64']) ==
                 (b['code'], b['stdout_b64'], b['stderr_b64'])
                 for a, b in zip(bundles['bash']['runs'], bundles['lua']['runs']))
    rounds.append({'round': i + 1, 'parity': parity, 'bundles': bundles})
result = {'scope': 'Five alternating pairs of three live decisions with own copied executables, guard/module and input files advised DONTNEED and residency probed with mincore immediately before each bundle. Not globally OS-cold: shared libraries, metadata, system utilities and kernel caches remain warm. Parent full gate may run concurrently. Only files created by this harness are advised; no global cache mutation.',
          'source_ref': subprocess.check_output(['git', 'rev-parse', REF], cwd=WORK, text=True).strip(),
          'release_snapshot_source': str(source_binary), 'scratch': str(BASE),
          'filesystem': subprocess.check_output(['findmnt', '-T', str(BASE), '-no', 'FSTYPE'], text=True).strip(),
          'page_size': PAGE, 'identities': identities, 'rounds': rounds,
          'all_byte_parity': all(r['parity'] for r in rounds),
          'all_owned_files_nonresident_before_every_bundle': all(
              v['resident'] == 0 for r in rounds for b in r['bundles'].values()
              for v in b['before_residency'].values())}
path = OUT / 'pr-203-own-file-cold.json'
path.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'receipt': str(path), 'sha256': sha(path.read_bytes()),
                  'all_byte_parity': result['all_byte_parity'],
                  'all_owned_files_nonresident_before_every_bundle': result['all_owned_files_nonresident_before_every_bundle'],
                  'pairs': [{'bash_ms': r['bundles']['bash']['wall_ns']/1e6,
                             'lua_ms': r['bundles']['lua']['wall_ns']/1e6} for r in rounds]}, indent=2))
assert result['all_byte_parity']
