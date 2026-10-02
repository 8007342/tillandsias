#!/usr/bin/env python3
"""Linux/x86_64 child-only ptrace probe. No attach, root, install, or timing.
Run with python3 -B trace_children.py. Traces only forked TRACEME children.
Preserves stdout/stderr in separate regular files to avoid pipe deadlock.
"""
import base64
import ctypes
import datetime
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import time
import measure

BASE = Path(__file__).resolve().parent
ACCEPTED = BASE / 'run-20261002T060948.342189Z/receipts.json'
libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
libc.ptrace.restype = ctypes.c_long
TRACEME, CONT, SETOPTIONS, GETEVENTMSG = 0, 7, 0x4200, 0x4201
OPTIONS = 2 | 4 | 8 | 16 | 64 | (1 << 20)
EVENTS = {1: 'fork', 2: 'vfork', 3: 'clone', 4: 'exec', 6: 'exit-pending'}
WALL = 0x40000000

def ptrace(request, pid, data=0):
    ctypes.set_errno(0)
    result = libc.ptrace(request, pid, None, ctypes.c_void_p(data))
    if result == -1:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))
    return result

def message(pid):
    value = ctypes.c_ulong()
    ptrace(GETEVENTMSG, pid, ctypes.addressof(value))
    return value.value

def identity(tid):
    # Called ONLY for a root we forked or a child TID reported by ptrace.
    fields = {}
    for line in Path(f'/proc/{tid}/status').read_text().splitlines():
        if line.startswith(('Name:', 'Tgid:', 'Pid:', 'PPid:')):
            k, v = line.split(':', 1)
            fields[k] = v.strip()
    return {'tid': int(fields['Pid']), 'tgid': int(fields['Tgid']),
            'ppid': int(fields['PPid']), 'name': fields['Name']}

def receipt_bytes(path):
    b = path.read_bytes()
    return {'b64': base64.b64encode(b).decode(), 'sha256': measure.digest(b),
            'length': len(b)}

def trace(case, profile, out):
    argv, env = measure.command(case, profile)
    stem = profile + '-' + case['id']
    stdout = out / (stem + '.stdout')
    stderr = out / (stem + '.stderr')
    outfd = os.open(stdout, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    errfd = os.open(stderr, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    root = os.fork()
    if root == 0:
        try:
            os.dup2(outfd, 1)
            os.dup2(errfd, 2)
            os.close(outfd)
            os.close(errfd)
            fd = os.open('/dev/null', os.O_RDONLY)
            os.dup2(fd, 0)
            os.close(fd)
            os.chdir(case['root'])
            ptrace(TRACEME, 0)
            os.kill(os.getpid(), signal.SIGSTOP)
            os.execve(argv[0], argv, env)
        except BaseException as e:
            os.write(2, ('unavailable:child-trace-setup:' + repr(e) + '\n').encode())
            os._exit(125)
    os.close(outfd)
    os.close(errfd)
    known, alive, initial_stops, early_stops = {}, {root}, set(), {}
    events, root_exit, error = [], None, None
    try:
        pid, status = os.waitpid(root, 0)
        if not os.WIFSTOPPED(status) or os.WSTOPSIG(status) != signal.SIGSTOP:
            raise RuntimeError('initial TRACEME stop unavailable: ' + str(status))
        known[root] = identity(root)
        events.append({'event': 'harness-launch', **known[root], 'wait_status': status})
        ptrace(SETOPTIONS, root, OPTIONS)
        ptrace(CONT, root)
        deadline = time.monotonic() + 30
        while alive:
            if time.monotonic() > deadline:
                raise RuntimeError('trace deadline; counts incomplete')
            pid, status = os.waitpid(-1, WALL | os.WNOHANG)
            if pid == 0:
                time.sleep(.001)
                continue
            if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                value = os.waitstatus_to_exitcode(status)
                events.append({'event': 'reaped', 'tid': pid, 'exit': value,
                               'wait_status': status})
                alive.discard(pid)
                if pid == root:
                    root_exit = value
                continue
            if not os.WIFSTOPPED(status):
                raise RuntimeError('unexpected wait status: ' + str(status))
            sig, event = os.WSTOPSIG(status), status >> 16
            # waitpid(-1) may deliver the automatically stopped child's status
            # BEFORE the creator's birth event. Hold it stopped until that
            # event establishes identity; do not infer a birth from the stop.
            if not event and sig == signal.SIGSTOP and pid not in known:
                early_stops[pid] = status
                alive.add(pid)
                events.append({'event': 'early-child-stop-held', 'tid': pid,
                               'wait_status': status})
                continue
            if event:
                name = EVENTS.get(event)
                if name is None:
                    raise RuntimeError('unhandled ptrace event: ' + str(event))
                msg = message(pid)
                entry = {'event': name, 'tid': pid, 'message': msg,
                         'wait_status': status}
                if event in (1, 2, 3):
                    child = identity(msg)
                    parent = identity(pid)
                    known[msg] = child
                    alive.add(msg)
                    if msg in early_stops:
                        entry['initial_stop_already_received'] = early_stops.pop(msg)
                        ptrace(CONT, msg)
                    else:
                        initial_stops.add(msg)
                    entry.update(parent=parent, child=child,
                                 birth_kind='thread' if child['tgid'] == parent['tgid'] else 'process')
                elif event == 4:
                    if msg != pid:
                        raise RuntimeError('nonleader exec TID remap: refuse incomplete classification')
                    entry['identity'] = identity(pid)
                    entry['exe'] = os.readlink(f'/proc/{pid}/exe')
                events.append(entry)
                ptrace(CONT, pid)
            elif sig == signal.SIGSTOP and pid in initial_stops:
                initial_stops.remove(pid)
                events.append({'event': 'new-child-stop', 'tid': pid,
                               'identity': identity(pid), 'wait_status': status})
                ptrace(CONT, pid)
            else:
                # Preserve real signal delivery (including SIGCHLD). Never
                # silently suppress an unknown trap/group-stop.
                if pid not in known:
                    raise RuntimeError('stop before accounted birth: ' + str(pid))
                if sig in (signal.SIGTRAP, signal.SIGSTOP):
                    raise RuntimeError('unhandled signal stop: ' + str(sig))
                events.append({'event': 'signal-delivery', 'tid': pid, 'signal': sig,
                               'wait_status': status})
                ptrace(CONT, pid, sig)
        if early_stops:
            raise RuntimeError('child stop never matched to a birth event')
    except BaseException as e:
        error = 'unavailable:ptrace:' + repr(e)
        # Only known harness descendants, never arbitrary process attachment.
        for pid in alive:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        end = time.monotonic() + 3
        while alive and time.monotonic() < end:
            try:
                pid, status = os.waitpid(-1, WALL | os.WNOHANG)
            except ChildProcessError:
                break
            if not pid:
                time.sleep(.001)
            elif os.WIFSTOPPED(status):
                try:
                    ptrace(CONT, pid, signal.SIGKILL)
                except OSError:
                    pass
            else:
                alive.discard(pid)
    births = [e for e in events if e['event'] in ('fork', 'vfork', 'clone')]
    group_ids = {i['tgid'] for i in known.values()}
    counts = None if error else {
        'harness_launches': 1,
        'descendant_processes': sum(e['birth_kind'] == 'process' for e in births),
        'descendant_threads': sum(e['birth_kind'] == 'thread' for e in births),
        'distinct_thread_groups_including_launch': len(group_ids),
        'distinct_tids_including_launch': len(known),
        'fork_events': sum(e['event'] == 'fork' for e in births),
        'vfork_events': sum(e['event'] == 'vfork' for e in births),
        'clone_events': sum(e['event'] == 'clone' for e in births),
        'exec_events': sum(e['event'] == 'exec' for e in events),
    }
    if counts is not None and counts['distinct_thread_groups_including_launch'] != counts['descendant_processes'] + 1:
        error, counts = 'unavailable:ptrace:thread-group-count-inconsistent', None
    return {'case': case['id'], 'profile': profile, 'argv': argv,
            'cwd': case['root'], 'environment': env, 'root_tid': root,
            'exit': root_exit, 'stdout': receipt_bytes(stdout),
            'stderr': receipt_bytes(stderr), 'error': error, 'counts': counts,
            'events': events, 'known_tasks': known}

def main():
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        print('unavailable:ptrace:unsupported-platform')
        return
    accepted_bytes = ACCEPTED.read_bytes()
    accepted = json.loads(accepted_bytes)
    expected_hash = accepted['provenance']['identities']['release']['sha256']
    binary_hash = measure.digest((BASE / 'plan-release').read_bytes())
    assert binary_hash == expected_hash, 'retained release snapshot changed'
    assert measure.digest((BASE/'source-agreements.lua').read_bytes()) == accepted['provenance']['lua_sha256']
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    out = BASE / ('trace-' + stamp)
    out.mkdir()
    traces = []
    for name in ['tray-live', 'dev-model-live', 'inference-live']:
        case = next(c for c in accepted['cases'] if c['id'] == name)
        previous = next(c for c in accepted['parity'] if c['case'] == name)
        for profile in ['old', 'release']:
            result = trace(case, profile, out)
            expected = previous['old'] if profile == 'old' else previous['new'][profile]
            result['matches_accepted'] = (result['exit'] == expected['exit'] and
                result['stdout']['b64'] == expected['stdout_b64'] and
                result['stderr']['b64'] == expected['stderr_b64'])
            traces.append(result)
            if result['error']:
                break
        if traces[-1]['error']:
            break
    totals = {}
    for profile in ['old', 'release']:
        selected = [t for t in traces if t['profile'] == profile]
        if len(selected) == 3 and all(t['counts'] is not None for t in selected):
            totals[profile] = {k: sum(t['counts'][k] for t in selected)
                               for k in selected[0]['counts']}
    paired = {}
    for name in ['tray-live', 'dev-model-live', 'inference-live']:
        ts = [t for t in traces if t['case'] == name]
        paired[name] = len(ts) == 2 and all(ts[0][k] == ts[1][k] for k in ['exit','stdout','stderr'])
    result = {
        'method': 'Linux ptrace TRACEME then SIGSTOP; TRACEFORK/VFORK/CLONE/EXEC/EXIT and EXITKILL; waitpid __WALL; no attach',
        'scope': 'only six harness-launched synthetic guard processes and their descendants; tracing is separate from accepted timing samples',
        'definitions': {'harness_launch': 'one tracer fork, followed by exec of Bash or plan-release',
                        'descendant_process': 'ptrace birth whose child TGID differs from parent TGID',
                        'descendant_thread': 'ptrace birth whose child TGID equals parent TGID',
                        'exec': 'successful exec ptrace event; image replacement does not create a process; includes launch exec',
                        'tgid': 'read from /proc/<known-child-tid>/status at ptrace birth stop, before resuming parent'},
        'limitations': 'ordinary stopped-child snapshot, not global monitoring; no time measurements or general no-spawn proof; nonleader exec or unknown stop refuses rather than guessing',
        'accepted_receipts_sha256': measure.digest(accepted_bytes),
        'release_sha256': binary_hash,
        'release_build_id': accepted['provenance']['identities']['release']['build_id'],
        'bash_sha256': measure.digest(Path('/usr/bin/bash').read_bytes()),
        'lua_sha256': accepted['provenance']['lua_sha256'],
        'tracer_sha256': measure.digest(Path(__file__).read_bytes()),
        'traces': traces, 'totals': totals, 'paired_byte_parity': paired,
        'complete': len(traces) == 6 and all(t['error'] is None and t['matches_accepted'] for t in traces),
    }
    raw = (json.dumps(result, indent=2) + '\n').encode()
    measure.write(out / 'trace-receipts.json', raw)
    print(json.dumps({'receipt': str(out/'trace-receipts.json'), 'sha256': measure.digest(raw),
                      'totals': totals, 'paired_byte_parity': paired, 'complete': result['complete'],
                      'per_case': [{k:t[k] for k in ['case','profile','counts','error','matches_accepted']} for t in traces]}, indent=2))

if __name__ == '__main__':
    main()
