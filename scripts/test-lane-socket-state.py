# @trace spec:mcp-tool-socket
# Order 1863-eckw: lane_socket_state (images/default/lib-common.sh) names a
# stale lane socket. Run: python3 -I scripts/test-lane-socket-state.py images/default/lib-common.sh
import os, re, socket, subprocess, sys, tempfile

lib = open(sys.argv[1]).read()
fn = re.search(r"^lane_socket_state\(\) \{.*?^\}", lib, re.S | re.M).group(0)
d = tempfile.mkdtemp()

def state(path):
    env = dict(os.environ)
    if path is None:
        env.pop("TILLANDSIAS_CONTROL_SOCKET", None)
    else:
        env["TILLANDSIAS_CONTROL_SOCKET"] = path
    return subprocess.run(["bash", "-c", fn + "\nlane_socket_state"], env=env,
                          capture_output=True, text=True).stdout.strip()

stale = os.path.join(d, "stale.sock")
s = socket.socket(socket.AF_UNIX); s.bind(stale); s.close()
live = os.path.join(d, "live.sock")
l = socket.socket(socket.AF_UNIX); l.bind(live); l.listen()
got = {"stale": state(stale), "ready": state(live), "absent": state(os.path.join(d, "x")), "unset": state(None)}
print(got)
assert all(k == v for k, v in got.items()), got

# The flutter shim names a stale lane (exit 69, host_lane=stale) and does not
# claim staleness for a socket that is simply missing (negative control).
shim = os.path.join(os.path.dirname(sys.argv[1]), "cli", "flutter")
def shim_err(path):
    env = dict(os.environ, TILLANDSIAS_CONTROL_SOCKET=path)
    r = subprocess.run([sys.executable, "-I", shim, "--version"], env=env, capture_output=True, text=True, timeout=20)
    return r.returncode, r.stderr
rc, err = shim_err(stale)
assert rc == 69 and "host_lane=stale" in err, (rc, err)
rc, err = shim_err(os.path.join(d, "x"))
assert rc == 69 and "host_lane=stale" not in err, (rc, err)
print("ok:lane-socket-state:6")
