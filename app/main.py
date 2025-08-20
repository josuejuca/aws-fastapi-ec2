# app/main.py
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse
import socket, time, datetime as dt
import httpx

# Endpoints corretos do IMDSv2 (EC2 metadata)
IMDS_BASE = "http://169.254.169.254/latest"
IMDS_TOKEN_URL = f"{IMDS_BASE}/api/token"
IMDS_HEADERS = {"X-aws-ec2-metadata-token-ttl-seconds": "21600"}

app = FastAPI(title="LB Probe API", version="1.0.0")

async def imds_get(path: str) -> str | None:
    """
    Lê metadados da instância via IMDSv2. Retorna None fora da AWS ou se bloqueado.
    """
    try:
        async with httpx.AsyncClient(timeout=0.5) as client:
            tok = None
            try:
                r = await client.put(IMDS_TOKEN_URL, headers=IMDS_HEADERS)
                if r.status_code == 200:
                    tok = r.text.strip()
            except httpx.HTTPError:
                pass

            headers = {"X-aws-ec2-metadata-token": tok} if tok else {}
            r2 = await client.get(f"{IMDS_BASE}/meta-data/{path}", headers=headers)
            if r2.status_code == 200:
                return r2.text.strip()
    except Exception:
        pass
    return None

def get_private_ip_fallback() -> str:
    try:
        hostname = socket.gethostname()
        return socket.gethostbyname(hostname)
    except Exception:
        return "desconhecido"

@app.get("/healthz", summary="Health check do ALB")
async def healthz():
    return PlainTextResponse("ok", status_code=200)

@app.get("/", summary="Root health with network info")
async def root(request: Request):
    t0 = time.perf_counter()

    host = request.headers.get("x-forwarded-host") or request.headers.get("host") or request.url.hostname
    scheme = request.headers.get("x-forwarded-proto") or request.url.scheme

    # Tenta EC2 metadata; se falhar, segue com fallback/local
    public_ip = await imds_get("public-ipv4")
    private_ip = await imds_get("local-ipv4") or get_private_ip_fallback()
    instance_id = await imds_get("instance-id")
    az = await imds_get("placement/availability-zone")

    ping_ms = round((time.perf_counter() - t0) * 1000, 2)

    payload = {
        "ok": True,
        "mensagem": "Teste de Load Balancing da AWS — FastAPI em execução.",
        "acesso": {
            "dns_usado": host,
            "esquema": scheme,
            "metodo": request.method,
            "path": request.url.path,
            "ip_cliente": request.headers.get("x-forwarded-for") or (request.client.host if request.client else None),
        },
        "instancia": {
            "ip_publico_vm": public_ip or "indisponivel",
            "ip_privado_vm": private_ip,
            "instance_id": instance_id or "desconhecido",
            "availability_zone": az or "desconhecida",
        },
        "ping_ms": ping_ms,
        "server_time_utc": dt.datetime.utcnow().isoformat() + "Z",
        "server_time_brt": dt.datetime.utcnow().astimezone(dt.timezone(dt.timedelta(hours=-3))).strftime("%d/%m/%Y %I:%M:%S %p UTC-3"),
        "version": "1.0.0",
    }
    return JSONResponse(payload)
