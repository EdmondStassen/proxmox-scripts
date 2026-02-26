#!/usr/bin/env bash
set -euo pipefail

# Proxmox LXC: news_fetch via Docker Compose
# - Pull private GitHub repo
# - Run docker compose
# - Avahi mDNS: news.local
# - Proxmox Notes with URLs + paths

export SSH_CLIENT="${SSH_CLIENT:-}"
export SSH_TTY="${SSH_TTY:-}"
export SSH_CONNECTION="${SSH_CONNECTION:-}"

set -euo pipefail
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

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
pct exec "$CTID" -- bash -lc '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg git
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  apt-get install -y docker-compose-plugin
  systemctl enable docker --now
' >/dev/null
msg_ok "Docker ready"

if [[ "${ENABLE_MDNS}" == "1" ]]; then
  msg_info "Installing & configuring Avahi (mDNS: ${MDNS_BASE}.local)"
  pct exec "$CTID" -- bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y avahi-daemon
    systemctl enable avahi-daemon --now
  ' >/dev/null

  pct exec "$CTID" -- bash -lc "
    set -e
    echo '${MDNS_BASE}' > /etc/hostname
    hostnamectl set-hostname '${MDNS_BASE}' || true
    if ! grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
      echo '127.0.1.1 ${MDNS_BASE}' >> /etc/hosts
    else
      sed -i -E 's/^127\.0\.1\.1\s+.*/127.0.1.1 ${MDNS_BASE}/' /etc/hosts
    fi
    systemctl restart avahi-daemon
  " >/dev/null
  msg_ok "mDNS configured"
fi

msg_info "Setting container root password"
pct exec "$CTID" -- bash -lc "echo root:${ROOT_PASS} | chpasswd" >/dev/null
msg_ok "Root password set"

msg_info "Cloning/updating repository"
pct exec "$CTID" -- bash -lc "
  set -e
  PROJECT_DIR='${PROJECT_DIR}'
  GIT_BRANCH='${GIT_BRANCH}'
  GIT_REPO='${GIT_REPO}'
  GITHUB_TOKEN='${GITHUB_TOKEN}'
  
  if [[ -d \"${PROJECT_DIR}/.git\" ]]; then
    cd \"${PROJECT_DIR}\"
    git fetch --all
    git checkout \"${GIT_BRANCH}\"
    git pull
  else
    rm -rf \"${PROJECT_DIR}\"
    if [[ -n \"${GITHUB_TOKEN}\" ]]; then
      git clone --branch \"${GIT_BRANCH}\" \"https://x-access-token:${GITHUB_TOKEN}@github.com/EdmondStassen/Supervisory_relations_newsletter.git\" \"${PROJECT_DIR}\"
    else
      git clone --branch \"${GIT_BRANCH}\" \"${GIT_REPO}\" \"${PROJECT_DIR}\"
    fi
  fi
" >/dev/null
msg_ok "Repository ready"

msg_info "Writing .env (secrets only)"
pct exec "$CTID" -- bash -lc "
  set -e
  mkdir -p '${PROJECT_DIR}'
  cat > '${ENV_FILE}' <<EOF
SMTP_PASSWORD=${SMTP_PASSWORD}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
EOF
" >/dev/null

if [[ -z \"${SMTP_PASSWORD}\" ]] || [[ -z \"${AWS_ACCESS_KEY_ID}\" ]] || [[ -z \"${AWS_SECRET_ACCESS_KEY}\" ]]; then
  msg_info "Some secrets are empty - they should be set via environment variables:"
  msg_info "  SMTP_PASSWORD - for email sending"
  msg_info "  AWS_ACCESS_KEY_ID - for S3 backup"
  msg_info "  AWS_SECRET_ACCESS_KEY - for S3 backup"
else
  msg_ok ".env written with all secrets"
fi

msg_info "Starting docker compose"
pct exec "$CTID" -- bash -lc "cd '${PROJECT_DIR}' && docker compose --env-file '${ENV_FILE}' up -d" >/dev/null
msg_ok "news_fetch started"

msg_info "Setting up cron for daily workflow (weekdays 07:45 update, 08:00 workflow)"
pct exec "$CTID" -- bash -lc "
  set -e
  apt-get install -y cron
  
  # Set timezone to Amsterdam
  ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
  echo 'Europe/Amsterdam' > /etc/timezone
  
  # Create cron jobs file
  cat > /etc/cron.d/news_fetch <<'CRONEOF'
# Git pull + restart container (07:45 weekdays)
45 7 * * 1-5 root cd ${PROJECT_DIR} && git pull >> ${PROJECT_DIR}/logs/git-update.log 2>&1 && docker compose --env-file ${ENV_FILE} restart >> ${PROJECT_DIR}/logs/git-update.log 2>&1

# Run workflow (08:00 weekdays)
0 8 * * 1-5 root cd ${PROJECT_DIR} && docker compose --env-file ${ENV_FILE} exec -T news_fetch python run_workflow.py >> ${PROJECT_DIR}/logs/cron.log 2>&1
CRONEOF
  chmod 0644 /etc/cron.d/news_fetch
  
  # Ensure cron is enabled and running
  systemctl enable cron --now
" >/dev/null
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

Commands:
- docker compose -f ${PROJECT_DIR}/docker-compose.yml --env-file ${ENV_FILE} up -d
- docker compose -f ${PROJECT_DIR}/docker-compose.yml --env-file ${ENV_FILE} logs -f
- docker compose -f ${PROJECT_DIR}/docker-compose.yml --env-file ${ENV_FILE} restart

Workflow Commands:
- python run_workflow.py (full workflow)
- python run_workflow_test.py (test with TEST_EMAIL)
- python stap0_environment.py (check/restore from S3)

Cron Schedule:
- 07:45 Mon-Fri: Git pull + container restart (logs/git-update.log)
- 08:00 Mon-Fri: Run workflow (logs/cron.log)
- Timezone: Amsterdam (Europe/Amsterdam)
- Check: cat /etc/cron.d/news_fetch

Environment Variables Set:
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
pct set "$CTID" --description "$DESC" >/dev/null
msg_ok "Notes written"

msg_ok "Completed successfully!"
echo -e "${INFO}${YW}Access (IP):${CL} ${URL_IP}"
if [[ "${ENABLE_MDNS}" == "1" ]]; then
  echo -e "${INFO}${YW}Access (mDNS):${CL} ${URL_DNS}"
fi
echo -e "${INFO}${YW}LXC root password:${CL} ${ROOT_PASS}"
echo -e "${INFO}${YW}Configuration stored in Proxmox Notes${CL}"

