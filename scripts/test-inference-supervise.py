#!/usr/bin/env python3
# @trace spec:inference-container, order:1859-v5iv
"""The inference entrypoint stops on SIGTERM instead of waiting out the stop timeout.

Runs images/inference/supervise.sh with a stub engine (a shell that records
the SIGTERM it receives and exits 0) and a second background job, as a plain
child and, where `unshare` can make one, as PID 1 of a new PID namespace (the
container case: the kernel drops a signal PID 1 has no handler for).

Arms:
  term        SIGTERM reaches the engine and the other job; the supervisor
              exits promptly with the engine's status.
  own-exit    an engine that exits 3 by itself exits the supervisor with 3.
  control     the old final line, `wait $OLLAMA_PID`, does NOT pass SIGTERM
              to the engine, so the `term` arm can tell the two apart.
  entrypoint  entrypoint.sh ends by sourcing the path the Containerfile copies
              supervise.sh to and calling tillandsias_supervise "$OLLAMA_PID".

Prints `ok:inference-supervise:<n>` when every arm holds.
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "images/inference/supervise.sh")
EP = os.path.join(ROOT, "images/inference/entrypoint.sh")
CF = os.path.join(ROOT, "images/inference/Containerfile")

STUB = """trap 'echo term > "$1"; exit 0' TERM
echo $$ > "$1.up"
while :; do sleep 0.1; done
"""

passed = 0
failed = 0


def ok(msg):
    global passed
    passed += 1
    print("ok:   " + msg)


def bad(msg):
    global failed
    failed += 1
    print("FAIL: " + msg, file=sys.stderr)


def reap(tmp):
    """Kill, by the pid each wrote, any stub a run left behind."""
    for name in ("engine.up", "job.up"):
        try:
            with open(os.path.join(tmp, name)) as f:
                os.kill(int(f.read().strip()), signal.SIGKILL)
        except (OSError, ValueError):
            pass


def wait_for(path, budget):
    end = time.time() + budget
    while time.time() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.05)
    return False


def run(tmp, tail, pid1, engine_exit=None):
    """Start bash running `tail` after an engine and a second job; return the Popen."""
    stub = os.path.join(tmp, "stub.sh")
    with open(stub, "w") as f:
        f.write(STUB if engine_exit is None else "sleep 0.3; exit %d\n" % engine_exit)
    script = os.path.join(tmp, "main.sh")
    with open(script, "w") as f:
        f.write(
            '. "%s"\n'
            'bash "%s" "%s/engine" &\n'
            "OLLAMA_PID=$!\n"
            'bash "%s" "%s/job" &\n'
            "%s\n" % (LIB, stub, tmp, os.path.join(tmp, "job.sh"), tmp, tail)
        )
    with open(os.path.join(tmp, "job.sh"), "w") as f:
        f.write(STUB)
    argv = ["bash", script]
    if pid1:
        argv = ["unshare", "--user", "--map-root-user", "--pid", "--fork", "--kill-child"] + argv
    return subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def signal_inner(p, pid1):
    """SIGTERM the supervising shell: the unshare child when it is PID 1."""
    if not pid1:
        p.send_signal(signal.SIGTERM)
        return
    out = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()
    if out:
        os.kill(int(out[0]), signal.SIGTERM)


def regimes():
    yield False
    probe = subprocess.run(
        ["unshare", "--user", "--map-root-user", "--pid", "--fork", "true"],
        capture_output=True,
    ) if shutil.which("unshare") else None
    if probe is not None and probe.returncode == 0:
        yield True
    else:
        print("skip: PID-1 regime (unshare cannot make a user+pid namespace here)")


for pid1 in regimes():
    where = "as PID 1" if pid1 else "as a child"

    with tempfile.TemporaryDirectory() as tmp:
        p = run(tmp, 'tillandsias_supervise "$OLLAMA_PID"', pid1)
        if not (wait_for(tmp + "/engine.up", 5) and wait_for(tmp + "/job.up", 5)):
            p.kill()
            bad("term %s: the stub engine never started" % where)
        else:
            t0 = time.time()
            signal_inner(p, pid1)
            try:
                rc = p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                rc = None
            took = time.time() - t0
            if rc == 0 and os.path.exists(tmp + "/engine") and os.path.exists(tmp + "/job"):
                ok("term %s: engine and job got SIGTERM, exit %d in %.1fs" % (where, rc, took))
            else:
                bad("term %s: rc=%s engine-signalled=%s job-signalled=%s" % (
                    where, rc, os.path.exists(tmp + "/engine"), os.path.exists(tmp + "/job")))
            reap(tmp)

    with tempfile.TemporaryDirectory() as tmp:
        p = run(tmp, 'tillandsias_supervise "$OLLAMA_PID"', pid1, engine_exit=3)
        try:
            rc = p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
            rc = None
        # The second job never ends by itself: as PID 1 the namespace takes it
        # down with the supervisor; as a child it is reaped below.
        reap(tmp)
        if rc == 3:
            ok("own-exit %s: the engine's own status 3 is the supervisor's" % where)
        else:
            bad("own-exit %s: rc=%s, want 3" % (where, rc))

    with tempfile.TemporaryDirectory() as tmp:
        p = run(tmp, 'wait "$OLLAMA_PID"', pid1)
        if wait_for(tmp + "/engine.up", 5):
            signal_inner(p, pid1)
            try:
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            signalled = wait_for(tmp + "/engine", 1)
            p.kill()
            p.wait()
            if not signalled:
                ok("control %s: a bare wait leaves the engine unsignalled (the arm can tell)" % where)
            else:
                bad("control %s: a bare wait also passed SIGTERM on, so `term` proves nothing" % where)
        else:
            p.kill()
            bad("control %s: the stub engine never started" % where)
        # Engines a bare wait orphaned outside a namespace.
        reap(tmp)

# entrypoint: the real final step, against the real install path.
dest = None
with open(CF) as f:
    m = re.search(r"^COPY supervise\.sh (\S+)$", f.read(), re.M)
    dest = m.group(1) if m else None
with open(EP) as f:
    code = [ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
if dest is None:
    bad("entrypoint: the Containerfile does not COPY supervise.sh into the image")
elif code[-2:] == [". %s" % dest, 'tillandsias_supervise "$OLLAMA_PID"']:
    ok("entrypoint: ends by sourcing %s and supervising ollama" % dest)
else:
    bad("entrypoint: last two commands are %r, want the supervisor from %s" % (code[-2:], dest))

if failed:
    print("inference-supervise: %d passed, %d failed" % (passed, failed))
    sys.exit(1)
print("ok:inference-supervise:%d" % passed)
