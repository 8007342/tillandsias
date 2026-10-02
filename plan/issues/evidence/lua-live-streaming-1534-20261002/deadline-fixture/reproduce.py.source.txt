#!/usr/bin/env python3
"""Bounded own-child experiment; Linux subreaper, no external attachments."""
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

BASE=Path(__file__).resolve().parent
ROOT=BASE/'repo'
ENV={'PATH':'/usr/bin:/bin','HOME':str(BASE),'TMPDIR':str(BASE),
     'LC_ALL':'C','LANG':'C','TZ':'UTC','TILLANDSIAS_REPO_ROOT':str(ROOT)}

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def inspect(who):
    try:
        text=Path('/proc/'+str(who['pid'])+'/stat').read_text()
    except FileNotFoundError:return {'exists':False,'same_identity':False,'running':False}
    fields=text[text.rfind(')')+2:].split()
    same=int(fields[19])==who['start_ticks']
    return {'exists':True,'same_identity':same,'state':fields[0],
            'running':same and fields[0] not in ['Z','X'],
            'ppid':int(fields[1]),'pgid':int(fields[2]),'start_ticks':int(fields[19])}

def reap(owned, events):
    # Reap only exact acknowledged identities. Grandchild may be reaped by its
    # original parent; that is checked separately via its receipt and /proc.
    for who in owned:
        observed=inspect(who)
        if observed['exists'] and not observed['same_identity']:continue
        try:
            pid,status=os.waitpid(who['pid'],os.WNOHANG)
        except ChildProcessError:continue
        if pid:events.append({'pid':pid,'start_ticks':who['start_ticks'],
                              'exit':os.waitstatus_to_exitcode(status)})

def trial(label,timeout):
    rundir=BASE/'runs'/label
    rundir.mkdir(parents=True)
    argv=[str(BASE/'plan'),'script','run',str(ROOT/'probe.lua'),
          '--timeout',timeout,'--',sys.executable,str(ROOT/'producer.py'),str(rundir)]
    started=time.monotonic_ns()
    proc=subprocess.Popen(argv,cwd=ROOT,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    ack=None; owned=[]; reaped=[]; cleanup=[]
    record={'label':label,'argv':argv,'environment':ENV,'outer_timeout':timeout,
            'process_timeout_ms':4000,'plan_pid':proc.pid}
    try:
        ack_limit=time.monotonic()+.6
        while time.monotonic()<ack_limit:
            if (rundir/'ack.json').exists():
                ack=json.loads((rundir/'ack.json').read_text());break
            if proc.poll() is not None:break
            time.sleep(.002)
        if ack:
            owned=[ack['child'],ack['grandchild']]
            record['ack']=ack
            record['ack_after_start_ms']=(ack['monotonic_ns']-started)/1e6
            record['at_ack']={role:inspect(ack[role]) for role in ['child','grandchild']}
        stdout,stderr=proc.communicate(timeout=5)
        ended=time.monotonic_ns()
        (rundir/'runner.stdout').write_bytes(stdout)
        (rundir/'runner.stderr').write_bytes(stderr)
        record.update(exit=proc.returncode,wall_ms=(ended-started)/1e6,
                      stdout=stdout.decode(),stderr=stderr.decode(),
                      stdout_sha256=hashlib.sha256(stdout).hexdigest(),
                      stderr_sha256=hashlib.sha256(stderr).hexdigest())
        record['after_outer_exit']={role:inspect(ack[role]) for role in ['child','grandchild']} if ack else {}
        record['markers_at_outer_exit']={role:(rundir/(role+'-marker.json')).exists()
                                         for role in ['child','grandchild']}
        if not ack:
            raise RuntimeError('invalid-experiment:no startup ACK before deadline')
        if record['ack_after_start_ms']>=600 or not all(v['running'] for v in record['at_ack'].values()):
            raise RuntimeError('invalid-experiment:startup identity/liveness not established')
        # Wait past the acknowledged marker schedules and natural-exit bound.
        finish=time.monotonic()+3
        while time.monotonic()<finish:
            reap(owned,reaped)
            if not any(inspect(w)['exists'] and inspect(w)['same_identity'] for w in owned):break
            time.sleep(.01)
        record['delayed_markers']={role:json.loads((rundir/(role+'-marker.json')).read_text())
                                  if (rundir/(role+'-marker.json')).exists() else None
                                  for role in ['child','grandchild']}
    except BaseException as e:
        record['error']=repr(e)
    finally:
        # Recover identities if an exception happened after fixture startup.
        if not owned and (rundir/'ack.json').exists():
            ack=json.loads((rundir/'ack.json').read_text());owned=[ack['child'],ack['grandchild']]
        if (rundir/'grandchild-ready.json').exists():
            g=json.loads((rundir/'grandchild-ready.json').read_text())
            if g not in owned:owned.append(g)
        if proc.poll() is None:
            proc.kill();proc.wait(timeout=2)
        for who in owned:
            status=inspect(who)
            if status['same_identity'] and status['running']:
                # Identity checked immediately before signalling, scoped to
                # owned fixture PID. No process-group or pattern-based kill.
                os.kill(who['pid'],signal.SIGKILL)
                cleanup.append({'signal':'SIGKILL',**who})
        limit=time.monotonic()+2
        while time.monotonic()<limit:
            reap(owned,reaped)
            if not any(inspect(w)['same_identity'] for w in owned):break
            time.sleep(.01)
        record['reaped_by_harness']=reaped
        record['forced_cleanup']=cleanup
        record['final_tasks']=[{'identity':w,'observed':inspect(w)} for w in owned]
        record['all_owned_tasks_gone']=bool(owned) and all(not inspect(w)['same_identity'] for w in owned)
        if (rundir/'grandchild-reaped.json').exists():
            record['grandchild_reaped_by_producer']=json.loads((rundir/'grandchild-reaped.json').read_text())
        (rundir/'receipt.json').write_text(json.dumps(record,indent=2)+'\n')
    return record

def main():
    libc=ctypes.CDLL(None,use_errno=True)
    if libc.prctl(36,1,0,0,0)!=0:
        raise OSError(ctypes.get_errno(),'unavailable:cannot-become-own-child-subreaper')
    build=subprocess.run([str(BASE/'plan'),'build-id'],cwd=ROOT,env=ENV,capture_output=True,text=True,check=True)
    receipt={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'copy':json.loads((BASE/'copy-provenance.json').read_text()),
             'build_id':build.stdout.strip(), 'plan_sha256':sha(BASE/'plan'),
             'fixture_hashes':{str(p.relative_to(BASE)):sha(p) for p in [ROOT/'producer.py',ROOT/'probe.lua',Path(__file__)]},
             'subreaper':True,
             'timing_note':'outer timer begins at script start; ACK is verified before deadline fires, not a separately armed timer',
             'trials':[trial('short-outer','700ms'),trial('positive-long-outer','3500ms')]}
    raw=(json.dumps(receipt,indent=2)+'\n').encode()
    (BASE/'receipts.json').write_bytes(raw)
    print(json.dumps({'receipt':str(BASE/'receipts.json'),'sha256':hashlib.sha256(raw).hexdigest(),
                      'build_id':receipt['build_id'],'trials':receipt['trials']},indent=2))

if __name__=='__main__':main()
