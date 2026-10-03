"""Authenticated Streamable HTTP runtime for WindowsBridge generations."""
from __future__ import annotations
import argparse, hmac, json, os
from pathlib import Path
import uvicorn
import windowsbridge

TOKEN_FILE=Path(os.environ.get("WINDOWSBRIDGE_BACKEND_TOKEN_FILE", r"C:\ProgramData\WindowsBridge\secrets\backend_token"))

def token()->str:
    v=TOKEN_FILE.read_text(encoding="utf-8").strip()
    if len(v)<32: raise RuntimeError("invalid backend secret")
    return v

def headers(scope):
    return {k.decode("latin1").lower():v.decode("latin1") for k,v in scope.get("headers",[])}

async def send_json(send,status,obj):
    body=json.dumps(obj,separators=(",",":")).encode()
    await send({"type":"http.response.start","status":status,"headers":[(b"content-type",b"application/json"),(b"content-length",str(len(body)).encode()),(b"cache-control",b"no-store")]})
    await send({"type":"http.response.body","body":body})

base=windowsbridge.mcp.streamable_http_app(streamable_http_path="/mcp",json_response=True,stateless_http=True,host="127.0.0.1")

class AuthRuntime:
    async def __call__(self,scope,receive,send):
        if scope["type"]=="lifespan":
            return await base(scope,receive,send)
        if scope["type"]!="http":
            return await base(scope,receive,send)
        supplied=headers(scope).get("x-bridge-backend-token","")
        try: ok=hmac.compare_digest(token(),supplied)
        except Exception: ok=False
        if not ok: return await send_json(send,403,{"ok":False,"error":"forbidden"})
        path=scope.get("path","")
        if path=="/healthz":
            return await send_json(send,200,{"ok":True,"pid":os.getpid(),"version":windowsbridge.VERSION})
        if path=="/__bridge/runtime-status":
            with windowsbridge._SESSIONS_GUARD:
                live=sum(1 for s in windowsbridge._SESSIONS.values() if s.proc.poll() is None)
            return await send_json(send,200,{"ok":True,"pid":os.getpid(),"live_process_sessions":live,"version":windowsbridge.VERSION})
        return await base(scope,receive,send)

def main():
    p=argparse.ArgumentParser(); p.add_argument("--port",type=int,required=True); a=p.parse_args()
    token()
    uvicorn.run(AuthRuntime(),host="127.0.0.1",port=a.port,log_level="warning",access_log=False)
if __name__=="__main__": main()
