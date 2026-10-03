"""Authenticated loopback generation router used by WindowsBridge seamless updates."""
from __future__ import annotations
import hmac, http.client, json, os, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT=Path(os.environ.get("WINDOWSBRIDGE_ROOT", os.path.join(os.environ.get("PROGRAMDATA", r"C:\ProgramData"),"WindowsBridge")))
STATE=ROOT/"state"; ROUTE=STATE/"route.json"; SECRETS=ROOT/"secrets"
ROUTER_TOKEN=SECRETS/"router_token"; BACKEND_TOKEN=SECRETS/"backend_token"
INFLIGHT={}; LOCK=threading.Lock(); MAX_BODY=8_000_000
HOP={"connection","keep-alive","proxy-authenticate","proxy-authorization","te","trailers","transfer-encoding","upgrade"}

def secret(p:Path)->str:
    v=p.read_text(encoding="utf-8").strip()
    if len(v)<32: raise RuntimeError("invalid local secret")
    return v

def route()->dict:
    d=json.loads(ROUTE.read_text(encoding="utf-8")); p=int(d["port"]); g=str(d["generation"])
    if not g or not 1024<=p<=65535: raise RuntimeError("invalid route")
    return {"generation":g,"port":p}

def add(g,d):
    with LOCK: INFLIGHT[g]=max(0,INFLIGHT.get(g,0)+d)

class H(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"; server_version="WindowsBridgeSupervisor/1"
    def log_message(self,*_): return
    def out(self,status,obj):
        b=json.dumps(obj,separators=(",",":")).encode()
        self.send_response(status); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.send_header("Cache-Control","no-store"); self.end_headers(); self.wfile.write(b)
    def auth(self):
        try: ok=hmac.compare_digest(secret(ROUTER_TOKEN),self.headers.get("X-Bridge-Token",""))
        except Exception: ok=False
        if not ok: self.out(403,{"ok":False,"error":"forbidden"})
        return ok
    def do_GET(self):
        if not self.auth(): return
        if self.path=="/__bridge/healthz": return self.out(200,{"ok":True,"pid":os.getpid()})
        if self.path=="/__bridge/status":
            try:
                r=route()
                with LOCK: counts=dict(INFLIGHT)
                return self.out(200,{"ok":True,"pid":os.getpid(),"active_generation":r["generation"],"active_port":r["port"],"inflight":counts,"timestamp":int(time.time())})
            except Exception as e: return self.out(503,{"ok":False,"error":type(e).__name__})
        self.proxy()
    def do_POST(self):
        if self.auth(): self.proxy()
    def do_DELETE(self):
        if self.auth(): self.proxy()
    def proxy(self):
        try: r=route(); g=r["generation"]; port=r["port"]; bt=secret(BACKEND_TOKEN)
        except Exception as e: return self.out(503,{"ok":False,"error":type(e).__name__})
        try: n=int(self.headers.get("Content-Length","0"))
        except ValueError: return self.out(400,{"ok":False,"error":"content-length"})
        if n<0 or n>MAX_BODY: return self.out(413,{"ok":False,"error":"request-too-large"})
        body=self.rfile.read(n) if n else None
        headers={k:v for k,v in self.headers.items() if k.lower() not in HOP|{"host","x-bridge-token"}}
        headers["Host"]=f"127.0.0.1:{port}"; headers["X-Bridge-Backend-Token"]=bt
        add(g,1); conn=http.client.HTTPConnection("127.0.0.1",port,timeout=3600)
        try:
            conn.request(self.command,self.path,body=body,headers=headers); resp=conn.getresponse()
            self.send_response(resp.status,resp.reason); has_len=False
            for k,v in resp.getheaders():
                if k.lower() in HOP: continue
                if k.lower()=="content-length": has_len=True
                self.send_header(k,v)
            if not has_len: self.send_header("Connection","close"); self.close_connection=True
            self.end_headers()
            while True:
                chunk=resp.read(65536)
                if not chunk: break
                self.wfile.write(chunk); self.wfile.flush()
        except Exception:
            try: self.out(502,{"ok":False,"error":"backend-unavailable"})
            except Exception: pass
        finally: conn.close(); add(g,-1)

def main():
    STATE.mkdir(parents=True,exist_ok=True); secret(ROUTER_TOKEN); secret(BACKEND_TOKEN); route()
    s=ThreadingHTTPServer(("127.0.0.1",18766),H); s.daemon_threads=True; s.serve_forever()
if __name__=="__main__": main()
