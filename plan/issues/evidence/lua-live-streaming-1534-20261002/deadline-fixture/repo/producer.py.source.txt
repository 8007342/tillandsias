#!/usr/bin/env python3
"""Only owned scratch ACK/marker writes; both processes exit within ~2 seconds."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

def identity():
    text=Path('/proc/self/stat').read_text()
    fields=text[text.rfind(')')+2:].split()
    return {'pid':os.getpid(),'start_ticks':int(fields[19]),'pgid':os.getpgrp(),
            'ppid':os.getppid()}

def publish(path,data):
    temp=path.with_suffix('.tmp')
    temp.write_text(json.dumps(data)+'\n')
    temp.replace(path)

root=Path(sys.argv[2]).resolve()
assert root.parent.name == 'runs' and root.is_dir()
role=sys.argv[1]
if role == 'grandchild':
    me=identity()
    publish(root/'grandchild-ready.json',me)
    deadline=time.monotonic()+.5
    while not (root/'ack.json').exists():
        if time.monotonic()>deadline: sys.exit(32)
        time.sleep(.002)
    print('grandchild-running',flush=True)
    print('grandchild-stderr',file=sys.stderr,flush=True)
    time.sleep(1.2)
    publish(root/'grandchild-marker.json',dict(me,monotonic_ns=time.monotonic_ns()))
    time.sleep(.6)
    sys.exit(0)
assert role == 'child'
grandchild=subprocess.Popen([sys.executable,__file__,'grandchild',str(root)])
deadline=time.monotonic()+.5
while not (root/'grandchild-ready.json').exists():
    if time.monotonic()>deadline:
        grandchild.kill();grandchild.wait();sys.exit(33)
    time.sleep(.002)
g=json.loads((root/'grandchild-ready.json').read_text())
text=Path('/proc/'+str(g['pid'])+'/stat').read_text()
fields=text[text.rfind(')')+2:].split()
assert int(fields[19])==g['start_ticks'] and fields[0]!='Z'
me=identity()
publish(root/'ack.json',{'child':me,'grandchild':g,'monotonic_ns':time.monotonic_ns()})
print('child-ack-both-running',flush=True)
print('child-stderr',file=sys.stderr,flush=True)
time.sleep(1.2)
publish(root/'child-marker.json',dict(me,monotonic_ns=time.monotonic_ns()))
status=grandchild.wait(timeout=1.0)
publish(root/'grandchild-reaped.json',{'pid':g['pid'],'start_ticks':g['start_ticks'],'exit':status})
sys.exit(status)
