#!/usr/bin/env bash
set -Eeuo pipefail

# news_fetch LXC installer for Proxmox VE
# Base: community-scripts/ProxmoxVE install/docker-install.sh
# Added: LXC build + git repo + .env + docker compose + cron + Avahi mDNS + SSH + Proxmox Notes

echo "[INFO] Starting Proxmox installer: news_fetch (docker compose)"

# -------------------------
# Startup hardening (host)
# -------------------------
if ! command -v pct >/dev/null 2>&1; then
  echo "[ERROR] 'pct' not found. Run this on the Proxmox host."
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] 'curl' not found on host. Install it: apt-get update && apt-get install -y curl"
  exit 1
fi

HOST_LOG="${HOST_LOG:-/var/log/news_fetch_proxmox_install.log}"
touch "$HOST_LOG" 2>/dev/null || HOST_LOG="/tmp/news_fetch_proxmox_install.log"
echo "[INFO] Host log: $HOST_LOG"
exec > >(tee -a "$HOST_LOG") 2>&1

on_err() {
  local ec=$?
  echo "[ERROR] Failed (exit=$ec) at line $1 while running: ${BASH_COMMAND}"
  echo "[ERROR] See log: $HOST_LOG"
  exit "$ec"
}
trap 'on_err $LINENO' ERR
trap 'echo "[WARN] Interrupted (Ctrl-C). See log: '"$HOST_LOG"'"; exit 130' INT

# Load helper functions (community-scripts build.func)
BUILD_FUNC_URL="${BUILD_FUNC_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func}"
BUILD_FUNC_PATH="/tmp/build.func"
echo "[INFO] Downloading build.func..."
curl --connect-timeout 10 --max-time 60 -fSL "$BUILD_FUNC_URL" -o "$BUILD_FUNC_PATH"
# shellcheck source=/tmp/build.func
source "$BUILD_FUNC_PATH"
echo "[INFO] build.func loaded."

# -------------------------
# Defaults / user overrides
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

# Your app port (used in Notes only). Override if your compose publishes something else (e.g. 5678).
HOST_PORT="${HOST_PORT:-8080}"

# mDNS
MDNS_BASE="${MDNS_BASE:-${var_hostname}}"
ENABLE_MDNS="${ENABLE_MDNS:-1}"

# Repo
GIT_REPO="${GIT_REPO:-https://github.com/EdmondStassen/Supervisory_relations_newsletter.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

PROJECT_DIR="${PROJECT_DIR:-/opt/news_fetch}"
ENV_FILE="${ENV_FILE:-${PROJECT_DIR}/.env}"

# Secrets for .env (same keys as your prior script)
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

# Docker options (mirrors docker-install.sh behavior, but non-interactive)
INSTALL_PORTAINER="${INSTALL_PORTAINER:-0}"          # 1=yes
INSTALL_PORTAINER_AGENT="${INSTALL_PORTAINER_AGENT:-0}"  # 1=yes (if Portainer not installed)
EXPOSE_DOCKER_SOCKET="${EXPOSE_DOCKER_SOCKET:-}"     # "", "l" (127.0.0.1), "a" (0.0.0.0)

header_info "$APP"
variables
color
catch_errors

strip_ansi(){ sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'; }
first_ipv4(){ grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1; }

pct_exec() {
  # Usage: pct_exec "<command>" ["label"]
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

# -------------------------
# Build LXC container
# -------------------------
start
build_container
description

# -------------------------
# Inside LXC: Docker install (based on docker-install.sh)
# -------------------------
pct_exec '
  set -e
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg jq git

  # Match docker-install.sh: journald logging
  DOCKER_CONFIG_PATH="/etc/docker/daemon.json"
  mkdir -p "$(dirname "$DOCKER_CONFIG_PATH")"
  cat > "$DOCKER_CONFIG_PATH" <<EOF
{
  "log-driver": "journald"
}
EOF

  # Install Docker (includes Compose/Buildx in modern packages)
  sh <(curl -fsSL https://get.docker.com)

  systemctl enable docker --now || true
  docker --version
  docker compose version || true
' "Install Docker (get.docker.com) + daemon.json"

# Optional: Portainer or Portainer Agent (same containers/ports as docker-install.sh)
if [[ "${INSTALL_PORTAINER}" == "1" ]]; then
  pct_exec '
    set -e
    docker volume create portainer_data >/dev/null
    docker run -d \
      -p 8000:8000 \
      -p 9443:9443 \
      --name=portainer \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest
  ' "Install Portainer (optional)"
elif [[ "${INSTALL_PORTAINER_AGENT}" == "1" ]]; then
  pct_exec '
    set -e
    docker run -d \
      -p 9001:9001 \
      --name portainer_agent \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /var/lib/docker/volumes:/var/lib/docker/volumes \
      portainer/agent
  ' "Install Portainer Agent (optional)"
fi

# Optional: expose Docker TCP socket like docker-install.sh
case "${EXPOSE_DOCKER_SOCKET,,}" in
  l) DOCKER_TCP="tcp://127.0.0.1:2375" ;;
  a) DOCKER_TCP="tcp://0.0.0.0:2375" ;;
  *) DOCKER_TCP="" ;;
esac

if [[ -n "$DOCKER_TCP" ]]; then
  pct_exec "
    set -e
    apt-get update -y
    apt-get install -y jq

    tmpfile=\$(mktemp)
    jq --arg sock \"$DOCKER_TCP\" '. + {\"hosts\": [\"unix:///var/run/docker.sock\", \$sock] }' /etc/docker/daemon.json >\"\$tmpfile\"
    mv \"\$tmpfile\" /etc/docker/daemon.json

    mkdir -p /etc/systemd/system/docker.service.d
    cat >/etc/systemd/system/docker.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
EOF

    systemctl daemon-reexec || true
    systemctl daemon-reload
    systemctl restart docker
  " "Expose Docker TCP socket (${DOCKER_TCP})"
fi

# -------------------------
# Your added functionality
# -------------------------

# SSH (so your Notes "ssh root@IP" works)
pct_exec '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y openssh-server
  systemctl enable ssh --now || systemctl enable sshd --now || true
' "Install SSH server"

# mDNS (Avahi)
if [[ "${ENABLE_MDNS}" == "1" ]]; then
  pct_exec '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y avahi-daemon
    systemctl enable avahi-daemon --now
  ' "Install Avahi (mDNS)"

  pct_exec "
    set -e
    echo '${MDNS_BASE}' > /etc/hostname
    hostnamectl set-hostname '${MDNS_BASE}' || true
    if ! grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
      echo '127.0.1.1 ${MDNS_BASE}' >> /etc/hosts
    else
      sed -i -E 's/^127\.0\.1\.1\s+.*/127.0.1.1 ${MDNS_BASE}/' /etc/hosts
    fi
    systemctl restart avahi-daemon
  " "Configure hostname for mDNS"
fi

# Root password
pct_exec "echo root:${ROOT_PASS} | chpasswd" "Set container root password"

# Clone/update repo
pct_exec "
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
      # Token clone path kept compatible with your previous script (repo can still be overridden by GIT_REPO)
      # If you want token clone for arbitrary repos, set GIT_REPO to github.com/<owner>/<repo>.git
      git clone --branch \"\${GIT_BRANCH}\" \"https://x-access-token:\${GITHUB_TOKEN}@github.com/EdmondStassen/Supervisory_relations_newsletter.git\" \"\${PROJECT_DIR}\"
    else
      git clone --branch \"\${GIT_BRANCH}\" \"\${GIT_REPO}\" \"\${PROJECT_DIR}\"
    fi
  fi
" "Git clone/pull newsletter repo"

# Project dirs + .env
pct_exec "mkdir -p '${PROJECT_DIR}/logs'" "Create logs directory"

pct_exec "
  set -e
  if [[ -f '${ENV_FILE}' ]]; then
    cp -f '${ENV_FILE}' '${ENV_FILE}.bak.\$(date +%Y%m%d%H%M%S)' || true
  fi
  cat > '${ENV_FILE}' <<EOF
SMTP_PASSWORD=${SMTP_PASSWORD}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
EOF
  chmod 0600 '${ENV_FILE}' || true
" "Write .env"

if [[ -z "${SMTP_PASSWORD}" || -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  msg_info "One or more secrets are empty; workflow may fail until you provide them:"
  msg_info "  SMTP_PASSWORD / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
fi

# Start compose
pct_exec "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' up -d" "docker compose up -d (project)"

# Verify
msg_info "Verifying compose (ps + logs)"
pct exec "$CTID" -- bash -lc "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' ps" || true
pct exec "$CTID" -- bash -lc "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' logs --tail=120" || true
msg_ok "Verification complete"

# Cron (weekday update + run)
pct_exec "
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

# Notes
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

Docker options:
- Portainer: ${INSTALL_PORTAINER}
- Portainer Agent: ${INSTALL_PORTAINER_AGENT}
- Docker TCP socket: ${EXPOSE_DOCKER_SOCKET}

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
