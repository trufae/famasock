#!/usr/bin/env python3
"""Real daemon/control-socket/CLI smoke test; no external network dependency."""
import json, os, socket, struct, subprocess, sys, tempfile, time
from pathlib import Path
binary = str(Path(sys.argv[1] if len(sys.argv)>1 else 'target/debug/famasock').resolve())
def rpc(root, command):
    payload=json.dumps(command).encode()
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
        s.settimeout(15); s.connect(str(root/'control.sock'));s.sendall(b'\x01'+struct.pack('!I',len(payload))+payload)
        def read(n):
            out=b''
            while len(out)<n:
                part=s.recv(n-len(out))
                if not part: raise RuntimeError('control socket closed')
                out+=part
            return out
        assert read(1)==b'\x01'; size=struct.unpack('!I',read(4))[0]; assert size<=8192
        reply=json.loads(read(size))
        if 'error' in reply: raise RuntimeError(reply['error'])
        return reply['data']
with tempfile.TemporaryDirectory() as tmp:
    roots=[Path(tmp)/'home',Path(tmp)/'phone']; processes=[]
    try:
        for root in roots:
            processes.append(subprocess.Popen([binary,'--state',str(root),'serve','--name',root.name,'--offline'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE))
        for root in roots:
            deadline=time.monotonic()+10
            while not (root/'control.sock').exists():
                if time.monotonic()>deadline: raise RuntimeError('daemon startup timed out')
                time.sleep(.02)
        invitation=rpc(roots[0],{'op':'invite'})
        # CLI accepts on stdin, avoiding the secret in argv/history.
        join=subprocess.Popen([binary,'--state',str(roots[1]),'pair','--accept','-'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        join.stdin.write(invitation['uri']+'\n');join.stdin.close();join.stdin=None
        deadline=time.monotonic()+10
        while True:
            pending=rpc(roots[0],{'op':'pending'})
            if pending: break
            if time.monotonic()>deadline: raise RuntimeError('pairing request missing')
            time.sleep(.02)
        rpc(roots[0],{'op':'approve','id':pending[0]['id'],'accept':True})
        stdout,stderr=join.communicate(timeout=10);assert join.returncode==0,(stdout,stderr)
        status=json.loads(subprocess.check_output([binary,'--state',str(roots[0]),'peers']))
        assert status['peers'][0]['name']=='phone'
        subprocess.run([binary,'--state',str(roots[0]),'allow','phone','ssh','127.0.0.1:22'],check=True,stdout=subprocess.DEVNULL)
        services=json.loads(subprocess.check_output([binary,'--state',str(roots[1]),'connect','home']))
        assert services['services']==['ssh']
        subprocess.run([binary,'--state',str(roots[0]),'revoke','phone'],check=True,stdout=subprocess.DEVNULL)
        assert rpc(roots[0],{'op':'status'})['peers']==[]
        print('CLI daemon, pairing, permissions, services and revocation: PASS')
    finally:
        for p in processes: p.terminate()
        for p in processes:
            try: p.wait(timeout=10)
            except subprocess.TimeoutExpired: p.kill();p.wait();raise RuntimeError('daemon failed to shut down')
