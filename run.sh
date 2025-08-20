#!/usr/bin/env bash
# run.sh — Provisiona e sobe FastAPI (Gunicorn+Uvicorn) como serviço systemd
# Uso: sudo bash run.sh
set -euo pipefail

# ===================== CONFIG BÁSICA (edite se quiser) =====================
APP_NAME="ec2-api"                      # nome do serviço/systemd e pastas
APP_USER="ec2"                          # usuário de serviço (sem login)
APP_GROUP="${APP_USER}"
APP_DIR="$(pwd)"                        # diretório do repositório (onde você rodou o script)
PY_BIN="/usr/bin/python3"               # python3 do sistema
VENV_DIR="${APP_DIR}/.venv"             # venv local ao repo
ENV_FILE="/etc/${APP_NAME}.env"         # env global do serviço

# Módulo ASGI: "PACOTE.ARQUIVO:app" — para app/main.py com FastAPI() chamada "app":
APP_MODULE_DEFAULT="app.main:app"

# Porta interna na EC2 (o Target Group do ALB deve apontar para esta)
APP_PORT_DEFAULT="8000"

# Tuning Gunicorn
WORKERS_DEFAULT="4"                     # regra prática: 2–4 por vCPU (ajuste após medir)
TIMEOUT_DEFAULT="90"                    # segundos
GRACEFUL_TIMEOUT_DEFAULT="30"
# ==========================================================================

if [[ $EUID -ne 0 ]]; then
  echo "Este script precisa rodar com sudo/root." >&2
  exit 1
fi

echo "==> (1/9) Instalando pacotes do sistema…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  python3-venv python3-pip python3-dev \
  build-essential pkg-config \
  ca-certificates curl git logrotate

echo "==> (2/9) Criando usuário/grupo de serviço (se não existir)…"
# grupo
if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
  groupadd --system "${APP_GROUP}"
fi
# usuário
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin -g "${APP_GROUP}" "${APP_USER}"
fi

echo "==> (3/9) Preparando virtualenv e dependências…"
if [[ ! -d "${VENV_DIR}" ]]; then
  "${PY_BIN}" -m venv "${VENV_DIR}"
fi
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip wheel setuptools

if [[ -f "${APP_DIR}/requirements.txt" ]]; then
  pip install -r "${APP_DIR}/requirements.txt"
else
  echo "requirements.txt não encontrado — instalando mínimos (fastapi, uvicorn, gunicorn, httpx)…"
  pip install fastapi "uvicorn[standard]" gunicorn httpx
fi

echo "==> (4/9) Gerando arquivo de ambiente ${ENV_FILE} (se não existir)…"
if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" <<EOF
# ${ENV_FILE} — variáveis lidas pelo systemd para ${APP_NAME}
ENV=prod
APP_MODULE="${APP_MODULE_DEFAULT}"
PORT="${APP_PORT_DEFAULT}"
WORKERS="${WORKERS_DEFAULT}"
TIMEOUT="${TIMEOUT_DEFAULT}"
GRACEFUL_TIMEOUT="${GRACEFUL_TIMEOUT_DEFAULT}"

# Exemplo de variáveis da sua app:
# DATABASE_URL="mysql+pymysql://user:pass@host:3306/db"
# SECRET_KEY="troque-isso"
EOF
fi
chmod 0640 "${ENV_FILE}"
chown root:"${APP_GROUP}" "${ENV_FILE}"

echo "==> (5/9) Permissões do diretório do app…"
# Dica: se o repo estiver em /home/ubuntu, manteremos ProtectHome=false no unit
chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"
chown -R "${APP_USER}:${APP_GROUP}" "${VENV_DIR}"

LOG_DIR="/var/log/${APP_NAME}"
mkdir -p "${LOG_DIR}"
touch "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"
chown -R "${APP_USER}:${APP_GROUP}" "${LOG_DIR}"
chmod 0755 "${LOG_DIR}"

echo "==> (6/9) Criando unidade systemd…"
/bin/cat > "/etc/systemd/system/${APP_NAME}.service" <<'UNIT'
[Unit]
Description=FastAPI (Gunicorn+Uvicorn)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=IMOGO_USER
Group=IMOGO_GROUP
WorkingDirectory=IMOGO_APPDIR
EnvironmentFile=/etc/IMOGO_APPNAME.env
Environment=PYTHONUNBUFFERED=1

# Gunicorn + UvicornWorker com logs em arquivo (para logrotate)
ExecStart=IMOGO_VENV/bin/gunicorn ${APP_MODULE} -k uvicorn.workers.UvicornWorker \
  --bind 0.0.0.0:${PORT} --workers ${WORKERS} \
  --timeout ${TIMEOUT} --graceful-timeout ${GRACEFUL_TIMEOUT} \
  --access-logfile /var/log/IMOGO_APPNAME/access.log \
  --error-logfile /var/log/IMOGO_APPNAME/error.log

Restart=always
RestartSec=3
KillSignal=SIGQUIT
TimeoutStopSec=30
LimitNOFILE=65535

# Segurança básica
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
# Se o repo ficar em /home/ubuntu, mantenha false. Se mover para /opt, pode trocar para true.
ProtectHome=false
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT

# Expandindo placeholders
sed -i "s|IMOGO_USER|${APP_USER}|g" "/etc/systemd/system/${APP_NAME}.service"
sed -i "s|IMOGO_GROUP|${APP_GROUP}|g" "/etc/systemd/system/${APP_NAME}.service"
sed -i "s|IMOGO_APPDIR|${APP_DIR}|g" "/etc/systemd/system/${APP_NAME}.service"
sed -i "s|IMOGO_VENV|${VENV_DIR}|g" "/etc/systemd/system/${APP_NAME}.service"
sed -i "s|IMOGO_APPNAME|${APP_NAME}|g" "/etc/systemd/system/${APP_NAME}.service"

echo "==> (7/9) Configurando logrotate…"
/bin/cat > "/etc/logrotate.d/${APP_NAME}" <<EOF
/var/log/${APP_NAME}/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
EOF

echo "==> (8/9) Subindo serviço…"
systemctl daemon-reload
systemctl enable "${APP_NAME}.service"
systemctl restart "${APP_NAME}.service"

sleep 1
systemctl --no-pager --full status "${APP_NAME}.service}" >/dev/null 2>&1 || true
systemctl --no-pager --full status "${APP_NAME}.service" || true

echo "==> (9/9) Dando uma conferida rápida…"
if command -v curl >/dev/null 2>&1; then
  # Tenta bater no healthz local (se existir)
  (curl -s -m 2 "http://127.0.0.1:$(grep -E '^PORT=' ${ENV_FILE} | cut -d= -f2 | tr -d '\"')/healthz" || true) >/dev/null
fi

echo
echo "✅ Pronto! Serviço '${APP_NAME}' rodando."
echo "   - Diretório do app: ${APP_DIR}"
echo "   - Venv: ${VENV_DIR}"
echo "   - Env file: ${ENV_FILE}"
echo "   - Logs: ${LOG_DIR}/{access.log,error.log}"
echo "   - Porta interna (TARGET GROUP/ALB): $(grep -E '^PORT=' ${ENV_FILE} | cut -d= -f2 | tr -d '\"')"
echo
echo "Comandos úteis:"
echo "  • Ver status:       systemctl status ${APP_NAME}"
echo "  • Logs ao vivo:     tail -f ${LOG_DIR}/error.log"
echo "  • Reiniciar:        systemctl restart ${APP_NAME}"
echo "  • Editar env:       sudo nano ${ENV_FILE}  # e depois: systemctl restart ${APP_NAME}"
