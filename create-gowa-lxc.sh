#!/usr/bin/env bash
# ProxmoxVE LXC helper (build.func framework)
# Deploys:
# - 2x GOWA/WhatsMeow bridge instances (2 WhatsApp numbers) via Docker image + Compose
# - 1x monitor instance (container) that checks both bridges and (later) emails QR reconnect info
#
# Notes:
# - Image-based (no git clone)
# - Separate volumes for whatsapp1/whatsapp2 (separate sessions)
# - Shared Basic Auth + shared webhook config (optional)
# - Monitor is a third container in its own compose project dir
# - This "base" version includes SMTP/login variables but does NOT yet implement email sending (placeholder)

set -euo pipefail

# Prevent "unbound variable" errors in Proxmox shell
: "${SSH_CLIENT:=}"
: "${SSH_TTY:=}"
: "${SSH_CONNECTION:=}"

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="GOWA"
var_tags="${var_tags:-docker;gowa;whatsapp;whatsmeow;monitor}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_hostname="${var_hostname:-gowa}"

# ---------------- Settings ----------------
# Instance 1 & 2 ports
HOST_PORT="${HOST_PORT:-3000}"
HOST_PORT_2="${HOST_PORT_2:-3001}"

# Shared Basic Auth (same for both)
GOWA_USER="${GOWA_USER:-admin}"
RAND_LEN="${RAND_LEN:-24}"

# Webhook (shared; optional; can be overridden)
WEBHOOK_URL="${WEBHOOK_URL:-http://whatsapp-bot.local:8080/webhook}"
WEBHOOK_EVENTS="${WEBHOOK_EVENTS:-message,message.ack}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}" # if empty -> generated

# Monitor settings
MONITOR_POLL_SECONDS="${MONITOR_POLL_SECONDS:-30}"
MONITOR_COOLDOWN_SECONDS="${MONITOR_COOLDOWN_SECONDS:-1800}" # avoid spamming alerts
MONITOR_PROJECT_DIR="${MONITOR_PROJECT_DIR:-/opt/gowa/monitor}"

# Email/SMTP settings (placeholders; we'll wire sending in the next step)
SMTP_HOST="${SMTP_HOST:-smtp.example.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-bot@example.com}"
SMTP_PASS="${SMTP_PASS:-CHANGE_ME}"
MAIL_FROM="${MAIL_FROM:-bot@example.com}"
MAIL_TO="${MAIL_TO:-you@example.com}"
MAIL_SUBJECT="${MAIL_SUBJECT:-[GOWA] Reconnect needed (QR)}"

header_info "$APP"
variables
var_install="docker-install"

color
catch_errors

# ---------------- helpers ----------------
rand_pw() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  else
    dd if=/dev/urandom bs=64 count=2 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  fi
}

msg_info "Generating credentials"
ROOT_PASS="$(rand_pw)"
GOWA_PASS="$(rand_pw)"
[[ -z "$WEBHOOK_SECRET" ]] && WEBHOOK_SECRET="$(rand_pw)"
msg_ok "Credentials generated"

# ---------------- create CT ----------------
start
build_container
description

# ---------------- Docker ----------------
msg_info "Installing Docker"
pct exec "$CTID" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
apt-get install -y docker-compose-plugin
systemctl enable docker --now
'
msg_ok "Docker ready"

# ---------------- root password ----------------
msg_info "Setting container root password"
pct exec "$CTID" -- bash -lc "echo root:${ROOT_PASS} | chpasswd"
msg_ok "Root password set"

# ---------------- Compose projects (2 instances) ----------------
msg_info "Creating Docker Compose projects (instance1 + instance2)"
pct exec "$CTID" -- bash -lc '
set -e

mkdir -p /opt/gowa/instance1 /opt/gowa/instance2

cat > /opt/gowa/instance1/docker-compose.yml <<EOF
services:
  whatsapp1:
    image: aldinokemal2104/go-whatsapp-web-multidevice
    container_name: whatsapp1
    restart: always
    ports:
      - "'"${HOST_PORT}"':3000"
    volumes:
      - whatsapp1:/app/storages
    environment:
      - APP_BASIC_AUTH='"${GOWA_USER}:${GOWA_PASS}"'
      - APP_PORT=3000
      - APP_DEBUG=true
      - APP_OS=Chrome
      - APP_ACCOUNT_VALIDATION=false
      - WEBHOOK_URL='"${WEBHOOK_URL}"'
      - WEBHOOK_EVENTS='"${WEBHOOK_EVENTS}"'
      - WEBHOOK_SECRET='"${WEBHOOK_SECRET}"'
volumes:
  whatsapp1:
EOF

cat > /opt/gowa/instance2/docker-compose.yml <<EOF
services:
  whatsapp2:
    image: aldinokemal2104/go-whatsapp-web-multidevice
    container_name: whatsapp2
    restart: always
    ports:
      - "'"${HOST_PORT_2}"':3000"
    volumes:
      - whatsapp2:/app/storages
    environment:
      - APP_BASIC_AUTH='"${GOWA_USER}:${GOWA_PASS}"'
      - APP_PORT=3000
      - APP_DEBUG=true
      - APP_OS=Chrome
      - APP_ACCOUNT_VALIDATION=false
      - WEBHOOK_URL='"${WEBHOOK_URL}"'
      - WEBHOOK_EVENTS='"${WEBHOOK_EVENTS}"'
      - WEBHOOK_SECRET='"${WEBHOOK_SECRET}"'
volumes:
  whatsapp2:
EOF

cd /opt/gowa/instance1 && docker compose up -d
cd /opt/gowa/instance2 && docker compose up -d
'
msg_ok "whatsapp1 + whatsapp2 started"

# ---------------- Monitor project (3rd instance) ----------------
# Base only: it checks both instances via Docker network name (http://whatsapp1:3000 / http://whatsapp2:3000)
# Email sending is not yet implemented: we just log to stdout for now.
msg_info "Creating monitor (instance3) project"
pct exec "$CTID" -- bash -lc '
set -e

mkdir -p "'"${MONITOR_PROJECT_DIR}"'"

cat > "'"${MONITOR_PROJECT_DIR}"'/docker-compose.yml <<EOF
services:
  gowa-monitor:
    image: alpine:3.20
    container_name: gowa-monitor
    restart: always
    environment:
      # Targets
      - TARGET_1=http://whatsapp1:3000
      - TARGET_2=http://whatsapp2:3000
      - BASIC_AUTH='"${GOWA_USER}:${GOWA_PASS}"'

      # Monitor behavior
      - POLL_SECONDS='"${MONITOR_POLL_SECONDS}"'
      - COOLDOWN_SECONDS='"${MONITOR_COOLDOWN_SECONDS}"'

      # Email/SMTP placeholders (we will implement later)
      - SMTP_HOST='"${SMTP_HOST}"'
      - SMTP_PORT='"${SMTP_PORT}"'
      - SMTP_USER='"${SMTP_USER}"'
      - SMTP_PASS='"${SMTP_PASS}"'
      - MAIL_FROM='"${MAIL_FROM}"'
      - MAIL_TO='"${MAIL_TO}"'
      - MAIL_SUBJECT='"${MAIL_SUBJECT}"'

    command: >
      sh -lc '
        set -e
        apk add --no-cache curl jq ca-certificates

        last_sent_1=0
        last_sent_2=0

        echo "[monitor] started; polling every ${POLL_SECONDS}s"

        check_target () {
          name="$1"
          base="$2"
          now="$3"

          # Basic check: try an authenticated endpoint.
          # If this returns non-2xx, we treat it as disconnected/unhealthy.
          if curl -fsS -u "${BASIC_AUTH}" "${base}/user/info" >/dev/null 2>&1; then
            echo "[monitor] ${name} OK"
            return 0
          fi

          echo "[monitor] ${name} NOT OK (needs reconnect)"
          return 1
        }

        while true; do
          now=$(date +%s)

          if ! check_target "whatsapp1" "${TARGET_1}" "$now"; then
            # placeholder action (email will come later)
            if [ $((now - last_sent_1)) -ge "${COOLDOWN_SECONDS}" ]; then
              echo "[monitor] ALERT placeholder: would email QR for whatsapp1"
              last_sent_1=$now
            fi
          fi

          if ! check_target "whatsapp2" "${TARGET_2}" "$now"; then
            # placeholder action (email will come later)
            if [ $((now - last_sent_2)) -ge "${COOLDOWN_SECONDS}" ]; then
              echo "[monitor] ALERT placeholder: would email QR for whatsapp2"
              last_sent_2=$now
            fi
          fi

          sleep "${POLL_SECONDS}"
        done
      '
EOF

cd "'"${MONITOR_PROJECT_DIR}"'" && docker compose up -d
'
msg_ok "Monitor container started (placeholder alerts only)"

# ---------------- Networking info ----------------
LXC_IP="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" | tr -d "\r" || true)"
DOCKER_IP_1="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' whatsapp1 2>/dev/null" | tr -d "\r" || true)"
DOCKER_IP_2="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' whatsapp2 2>/dev/null" | tr -d "\r" || true)"
DOCKER_IP_MON="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gowa-monitor 2>/dev/null" | tr -d "\r" || true)"

GOWA_URL_1="http://${LXC_IP}:${HOST_PORT}"
GOWA_URL_2="http://${LXC_IP}:${HOST_PORT_2}"

# ---------------- Proxmox Notes ----------------
msg_info "Writing Proxmox Notes"
DESC="$(cat <<EOF
GOWA / WhatsMeow – dual bridge + monitor

LXC:
- CTID: ${CTID}
- IP: ${LXC_IP}
- Root password: ${ROOT_PASS}

Bridge instance 1:
- URL: ${GOWA_URL_1}
- Container: whatsapp1
- Docker IP: ${DOCKER_IP_1}
- Volume: whatsapp1
- Compose: /opt/gowa/instance1/docker-compose.yml

Bridge instance 2:
- URL: ${GOWA_URL_2}
- Container: whatsapp2
- Docker IP: ${DOCKER_IP_2}
- Volume: whatsapp2
- Compose: /opt/gowa/instance2/docker-compose.yml

Monitor instance 3:
- Container: gowa-monitor
- Docker IP: ${DOCKER_IP_MON}
- Compose: ${MONITOR_PROJECT_DIR}/docker-compose.yml
- Checks: whatsapp1 + whatsapp2 via http://whatsapp1:3000 and http://whatsapp2:3000
- Poll: ${MONITOR_POLL_SECONDS}s, Cooldown: ${MONITOR_COOLDOWN_SECONDS}s
- Email: NOT YET IMPLEMENTED (placeholders only)

Basic Auth (shared):
- Username: ${GOWA_USER}
- Password: ${GOWA_PASS}

Webhook (shared):
- URL: ${WEBHOOK_URL}
- Secret: ${WEBHOOK_SECRET}
- Events: ${WEBHOOK_EVENTS}

SMTP (for monitor; placeholders right now):
- SMTP_HOST: ${SMTP_HOST}
- SMTP_PORT: ${SMTP_PORT}
- SMTP_USER: ${SMTP_USER}
- MAIL_FROM: ${MAIL_FROM}
- MAIL_TO: ${MAIL_TO}
- MAIL_SUBJECT: ${MAIL_SUBJECT}

Paths:
- Base: /opt/gowa
- Monitor: ${MONITOR_PROJECT_DIR}
EOF
)"
pct set "$CTID" --description "$DESC" >/dev/null
msg_ok "Notes written"

echo -e "${INFO}${YW}Instance 1:${CL} ${GOWA_URL_1}"
echo -e "${INFO}${YW}Instance 2:${CL} ${GOWA_URL_2}"
echo -e "${INFO}${YW}Monitor running (logs in docker):${CL} docker logs -f gowa-monitor"
echo -e "${INFO}${YW}Credentials stored in Proxmox Notes (CTID ${CTID}).${CL}"
