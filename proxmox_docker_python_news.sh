#!/usr/bin/env bash
set -euo pipefail

# Proxmox LXC: news_fetch via Docker Compose
# - Pull (optionally private) GitHub repo
# - Run docker compose
# - Avahi mDNS: news.local
# - Proxmox Notes with URLs + paths

# --- Pre-flight: make failures visible early ---
echo "[INFO] Starting Proxmox installer: news_fetch-docker"

# Log host-side output so you can review failures later
HOST_LOG="/var/log/news_fetch_proxmox_install.log"
touch "$HOST_LOG" 2>/dev/null || HOST_LOG="/tmp/news_fetch_proxmox_install.log"
echo "[INFO] Host log: $HOST_LOG" | tee -a "$HOST_LOG"

# Ensure we can fetch the helper library (build.func) reliably
BUILD_FUNC_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func"
BUILD_FUNC_PATH="/tmp/build.func"
if ! curl -fSL "$BUILD_FUNC_URL" -o "$BUILD_FUNC_PATH" >>"$HOST_LOG" 2>&1; then
  echo "[ERROR] Failed to download build.func from: $BUILD_FUNC_URL" | tee -a "$HOST_LOG"
  echo "[ERROR] Check DNS/Internet from the Proxmox host (raw.githubusercontent.com)." | tee -a "$HOST_LOG"
  exit 1
fi
# shellcheck source=/tmp/build.func
source "$BUILD_FUNC_PATH"

APP="news_fetch-docker"
var_tags="${var_tags:-docker;news_fetch;newsletter}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_hostname="${var_hostname:-news}"

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
  echo "[INFO] ${label}" >>"$HOST_LOG"
  # Let errors bubble up (set -e), but keep the full output in HOST_LOG.
  pct exec "$CTID" -- bash -lc "$cmd" >>"$HOST_LOG" 2>&1
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

msg_info "Installing Docker + Compose plugin (self-managed)"
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
msg_ok "Docker ready"

# Optional: SSH for the "ssh root@IP" note
msg_info "Installing SSH server (for ssh root@<IP>)"
pct_exec_logged '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y openssh-server
  systemctl enable ssh --now || systemctl enable sshd --now || true
' "Install openssh-server"
msg_ok "SSH ready"

if [[ "${ENABLE_MDNS}" == "1" ]]; then
  msg_info "Installing & configuring Avahi (mDNS: ${MDNS_BASE}.local)"
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
  msg_ok "mDNS configured"
fi

msg_info "Setting container root password"
pct_exec_logged "echo root:${ROOT_PASS} | chpasswd" "Set root password"
msg_ok "Root password set"

msg_info "Cloning/updating repository"
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
      git clone --branch \"\${GIT_BRANCH}\" \"https://x-access-token:\${GITHUB_TOKEN}@github.com/EdmondStassen/Supervisory_relations_newsletter.git\" \"\${PROJECT_DIR}\"
    else
      git clone --branch \"\${GIT_BRANCH}\" \"\${GIT_REPO}\" \"\${PROJECT_DIR}\"
    fi
  fi
" "Git clone/pull"
msg_ok "Repository ready"

msg_info "Preparing project directories"
pct_exec_logged "
  set -e
  mkdir -p '${PROJECT_DIR}/logs'
" "Create logs dir"
msg_ok "Directories ready"

msg_info "Writing .env (secrets only)"
# Keep close to your current approach: write the three keys into .env.
# But also back up any existing .env so secrets don't disappear accidentally.
pct_exec_logged "
  set -e
  mkdir -p '${PROJECT_DIR}'
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
if [[ -z "${SMTP_PASSWORD}" ]] || [[ -z "${AWS_ACCESS_KEY_ID}" ]] || [[ -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  msg_info "Some secrets are empty - set these env vars before running for full functionality:"
  msg_info "  SMTP_PASSWORD"
  msg_info "  AWS_ACCESS_KEY_ID"
  msg_info "  AWS_SECRET_ACCESS_KEY"
else
  msg_ok ".env written with all secrets"
fi

msg_info "Starting docker compose"
pct_exec_logged "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' up -d" "docker compose up -d"
msg_ok "news_fetch started"

msg_info "Verifying containers (docker compose ps + last logs)"
# Show a small summary to the console; full logs go to HOST_LOG.
pct exec "$CTID" -- bash -lc "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' ps" 2>&1 | tee -a "$HOST_LOG" || true
pct exec "$CTID" -- bash -lc "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' logs --tail=80" 2>&1 | tee -a "$HOST_LOG" || true
msg_ok "Verification done (see host log for details)"

msg_info "Setting up cron for daily workflow (weekdays 07:45 update, 08:00 workflow)"
pct_exec_logged "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y cron

  # Set timezone to Amsterdam
  ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
  echo 'Europe/Amsterdam' > /etc/timezone

  # Ensure logs directory exists
  mkdir -p '${PROJECT_DIR}/logs'

  # Create cron jobs file (IMPORTANT: variables are expanded here on purpose)
  cat > /etc/cron.d/news_fetch <<CRONEOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Git pull + restart container (07:45 weekdays)
45 7 * * 1-5 root cd ${PROJECT_DIR} && git pull >> ${PROJECT_DIR}/logs/git-update.log 2>&1 && docker compose --env-file ${ENV_FILE} restart >> ${PROJECT_DIR}/logs/git-update.log 2>&1

# Run workflow (08:00 weekdays)
0 8 * * 1-5 root cd ${PROJECT_DIR} && docker compose --env-file ${ENV_FILE} exec -T news_fetch python run_workflow.py >> ${PROJECT_DIR}/logs/cron.log 2>&1
CRONEOF

  chmod 0644 /etc/cron.d/news_fetch

  # Ensure cron is enabled and running
  systemctl enable cron --now
" "Configure cron"
msg_ok "Cron configured (07:45 git pull, 08:00 workflow)"

msg_info "Detecting IP and writing Proxmox Notes"
LXC_IP="$(detect_lxc_ip)"
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

Commands:
- docker compose -f ${PROJECT_DIR}/docker-compose.yml --env-file ${ENV_FILE} up -d
- docker compose -f ${PROJECT_DIR}/docker-compose.yml --env-file ${ENV_FILE} ps
- docker compose -f ${PROJECT_DIR}/docker-compose.yml --env-file ${ENV_FILE} logs -f

Workflow Commands:
- python run_workflow.py (full workflow)
- python run_workflow_test.py (test with TEST_EMAIL)
- python stap0_environment.py (check/restore from S3)

Cron Schedule:
- 07:45 Mon-Fri: Git pull + container restart (logs/git-update.log)
- 08:00 Mon-Fri: Run workflow (logs/cron.log)
- Timezone: Amsterdam (Europe/Amsterdam)
- Check: cat /etc/cron.d/news_fetch

Environment Variables Provided to Installer:
- GITHUB_TOKEN: ${GITHUB_TOKEN}
- SMTP_PASSWORD: ${SMTP_PASSWORD}
- AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
- AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}

Secrets:
- LXC root password: ${ROOT_PASS}

To Enter Container:
- ssh root@${LXC_IP}
EOF
)"
pct set "$CTID" --description "$DESC" >>"$HOST_LOG" 2>&1 || true
msg_ok "Notes written"

msg_ok "Completed successfully!"
echo -e "${INFO}${YW}Access (IP):${CL} ${URL_IP}"
if [[ "${ENABLE_MDNS}" == "1" ]]; then
  echo -e "${INFO}${YW}Access (mDNS):${CL} ${URL_DNS}"
fi
echo -e "${INFO}${YW}LXC root password:${CL} ${ROOT_PASS}"
echo -e "${INFO}${YW}Host log:${CL} ${HOST_LOG}"
echo -e "${INFO}${YW}Configuration stored in Proxmox Notes${CL}"
