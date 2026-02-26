#!/usr/bin/env bash
set -Eeuo pipefail

# Proxmox LXC: news_fetch via Docker Compose
# - Pull (optionally private) GitHub repo
# - Run docker compose
# - Avahi mDNS: news.local
# - Proxmox Notes with URLs + paths

# -------------------------
# BEGIN: startup hardening
# -------------------------
echo "[INFO] Starting Proxmox installer: news_fetch-docker"

# Basic host sanity checks (fail fast with a clear message)
if ! command -v pct >/dev/null 2>&1; then
  echo "[ERROR] 'pct' not found. This script must be run on the Proxmox host shell."
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] 'curl' not found on host. Install it: apt-get update && apt-get install -y curl"
  exit 1
fi

# Host-side log: mirror ALL output to screen AND file (fixes "web shell goes white" / no output)
HOST_LOG="/var/log/news_fetch_proxmox_install.log"
touch "$HOST_LOG" 2>/dev/null || HOST_LOG="/tmp/news_fetch_proxmox_install.log"
echo "[INFO] Host log: $HOST_LOG"
exec > >(tee -a "$HOST_LOG") 2>&1

# Helpful error handler: show line + last command
on_err() {
  local exit_code=$?
  echo "[ERROR] Script failed (exit=$exit_code) at line $1 while running: ${BASH_COMMAND}"
  echo "[ERROR] See log: $HOST_LOG"
  exit "$exit_code"
}
trap 'on_err $LINENO' ERR
trap 'echo "[WARN] Interrupted (Ctrl-C). See log: $HOST_LOG"; exit 130' INT

# Fetch helper library (build.func) with timeouts so it doesn't "hang at the beginning"
BUILD_FUNC_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func"
BUILD_FUNC_PATH="/tmp/build.func"
echo "[INFO] Downloading build.func..."
curl --connect-timeout 10 --max-time 60 -fSL "$BUILD_FUNC_URL" -o "$BUILD_FUNC_PATH"
# shellcheck source=/tmp/build.func
source "$BUILD_FUNC_PATH"
echo "[INFO] build.func loaded."
# -------------------------
# END: startup hardening
# -------------------------

APP="news_fetch-docker"
var_tags="${var_tags:-docker;news_fetch;newsletter}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_hostname="${var_hostname:-news}"

# NOTE: Your compose seems to publish 5678 (seen via docker-proxy), but keep 8080 default.
# Override at runtime: HOST_PORT=5678 ./script.sh
HOST_PORT="${HOST_PORT:-8080}"

MDNS_BASE="${MDNS_BASE:-${var_hostname}}"
ENABLE_MDNS="${ENABLE_MDNS:-1}"

GIT_REPO="${GIT_REPO:-https://github.com/EdmondStassen/Supervisory_relations_newsletter.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
PROJECT_DIR="/opt/news_fetch"
ENV_FILE="${PROJECT_DIR}/.env"

SMTP_PASSWORD="${SMTP_PASSWORD:-}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

header_info "$APP"
variables
color
catch_errors

strip_ansi(){ sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'; }
first_ipv4(){ grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1; }

pct_exec_logged() {
  # Usage: pct_exec_logged "<bash -lc command string>" ["label"]
  local cmd="${1:?missing command}"
  local label="${2:-pct exec}"
  msg_info "$label"
  pct exec "$CTID" -- bash -lc "$cmd"
  msg_ok "$label"
}

detect_lxc_ip() {
  local raw ip
  raw="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)"
  ip="$(printf '%s' "$raw" | strip_ansi | first_ipv4 || true)"
  if [[ -z "${ip}" ]]; then
    raw="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
    ip="$(printf '%s' "$raw" | strip_ansi | first_ipv4 || true)"
  fi
  [[ -z "${ip}" ]] && ip="(unknown)"
  printf '%s' "$ip"
}

msg_info "Generating root password"
ROOT_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)"
msg_ok "Root password generated"

start
build_container
description

pct_exec_logged '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg git
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  apt-get install -y docker-compose-plugin
  systemctl enable docker --now
  docker --version
  docker compose version
' "Install Docker + Compose"

# SSH so "ssh root@<IP>" works
pct_exec_logged '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y openssh-server
  systemctl enable ssh --now || systemctl enable sshd --now || true
' "Install SSH server"

if [[ "${ENABLE_MDNS}" == "1" ]]; then
  pct_exec_logged '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y avahi-daemon
    systemctl enable avahi-daemon --now
  ' "Install Avahi"

  pct_exec_logged "
    set -e
    echo '${MDNS_BASE}' > /etc/hostname
    hostnamectl set-hostname '${MDNS_BASE}' || true
    if ! grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
      echo '127.0.1.1 ${MDNS_BASE}' >> /etc/hosts
    else
      sed -i -E 's/^127\.0\.1\.1\s+.*/127.0.1.1 ${MDNS_BASE}/' /etc/hosts
    fi
    systemctl restart avahi-daemon
  " "Configure mDNS hostname"
fi

pct_exec_logged "echo root:${ROOT_PASS} | chpasswd" "Set container root password"

pct_exec_logged "
  set -e
  PROJECT_DIR='${PROJECT_DIR}'
  GIT_BRANCH='${GIT_BRANCH}'
  GIT_REPO='${GIT_REPO}'
  GITHUB_TOKEN='${GITHUB_TOKEN}'

  if [[ -d \"\${PROJECT_DIR}/.git\" ]]; then
    cd \"\${PROJECT_DIR}\"
    git fetch --all
    git checkout \"\${GIT_BRANCH}\"
    git pull
  else
    rm -rf \"\${PROJECT_DIR}\"
    if [[ -n \"\${GITHUB_TOKEN}\" ]]; then
      # Keep your original repo default but allow token-based clone
      git clone --branch \"\${GIT_BRANCH}\" \"https://x-access-token:\${GITHUB_TOKEN}@github.com/EdmondStassen/Supervisory_relations_newsletter.git\" \"\${PROJECT_DIR}\"
    else
      git clone --branch \"\${GIT_BRANCH}\" \"\${GIT_REPO}\" \"\${PROJECT_DIR}\"
    fi
  fi
" "Git clone/pull repo"

pct_exec_logged "mkdir -p '${PROJECT_DIR}/logs'" "Create logs directory"

# Write .env (back up any existing file first)
pct_exec_logged "
  set -e
  if [[ -f '${ENV_FILE}' ]]; then
    cp -f '${ENV_FILE}' '${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)' || true
  fi
  cat > '${ENV_FILE}' <<EOF
SMTP_PASSWORD=${SMTP_PASSWORD}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
EOF
  chmod 0600 '${ENV_FILE}' || true
" "Write .env"

msg_info "Starting docker compose"
pct exec "$CTID" -- bash -lc "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' up -d"
msg_ok "docker compose up -d"

msg_info "docker compose ps (verification)"
pct exec "$CTID" -- bash -lc "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' ps"
msg_ok "docker compose ps"

msg_info "docker compose logs (last 80 lines)"
pct exec "$CTID" -- bash -lc "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' logs --tail=80" || true
msg_ok "docker compose logs captured"

# Cron: IMPORTANT fix — do NOT single-quote heredoc marker, so variables expand into hard paths
pct_exec_logged "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y cron

  ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
  echo 'Europe/Amsterdam' > /etc/timezone

  mkdir -p '${PROJECT_DIR}/logs'

  cat > /etc/cron.d/news_fetch <<CRONEOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

45 7 * * 1-5 root cd ${PROJECT_DIR} && git pull >> ${PROJECT_DIR}/logs/git-update.log 2>&1 && docker compose --env-file ${ENV_FILE} restart >> ${PROJECT_DIR}/logs/git-update.log 2>&1
0 8 * * 1-5 root cd ${PROJECT_DIR} && docker compose --env-file ${ENV_FILE} exec -T news_fetch python run_workflow.py >> ${PROJECT_DIR}/logs/cron.log 2>&1
CRONEOF

  chmod 0644 /etc/cron.d/news_fetch
  systemctl enable cron --now
" "Configure cron"

msg_info "Detecting container IP"
LXC_IP="$(detect_lxc_ip)"
msg_ok "Container IP: ${LXC_IP}"

URL_IP="http://${LXC_IP}:${HOST_PORT}"
URL_DNS="http://${MDNS_BASE}.local:${HOST_PORT}"

msg_info "Writing Proxmox Notes"
DESC="$(
cat <<EOF
news_fetch via Docker in LXC (CTID ${CTID})

Access:
- URL (IP): ${URL_IP}
- URL (mDNS): ${URL_DNS}

mDNS:
- Hostname: ${MDNS_BASE}
- mDNS: ${MDNS_BASE}.local
- Avahi enabled: ${ENABLE_MDNS}

Repo:
- ${GIT_REPO}
- Branch: ${GIT_BRANCH}

Paths:
- Project: ${PROJECT_DIR}
- Env: ${ENV_FILE}
- Logs: ${PROJECT_DIR}/logs
- Host install log: ${HOST_LOG}

Secrets:
- LXC root password: ${ROOT_PASS}

To Enter Container:
- ssh root@${LXC_IP}

Debug:
- On host: tail -f ${HOST_LOG}
- In CT: cd ${PROJECT_DIR} && docker compose --env-file ${ENV_FILE} ps
- In CT: cd ${PROJECT_DIR} && docker compose --env-file ${ENV_FILE} logs -f
EOF
)"
pct set "$CTID" --description "$DESC" >/dev/null 2>&1 || true
msg_ok "Notes written"

msg_ok "Completed successfully!"
echo "[INFO] Access (IP): ${URL_IP}"
if [[ "${ENABLE_MDNS}" == "1" ]]; then
  echo "[INFO] Access (mDNS): ${URL_DNS}"
fi
echo "[INFO] LXC root password: ${ROOT_PASS}"
echo "[INFO] Host log: ${HOST_LOG}"
