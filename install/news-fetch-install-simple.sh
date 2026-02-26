#!/usr/bin/env bash

# Copyright (c) 2021-2026 tteck
# Author: Edmond Stassen (based on tteck's docker-install.sh)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.docker.com/ + https://github.com/EdmondStassen/Supervisory_relations_newsletter

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

DOCKER_LATEST_VERSION=$(get_latest_github_release "moby/moby")

msg_info "Installing Docker $DOCKER_LATEST_VERSION (with Compose, Buildx)"
DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
mkdir -p $(dirname $DOCKER_CONFIG_PATH)
echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
$STD sh <(curl -fsSL https://get.docker.com)
msg_ok "Installed Docker $DOCKER_LATEST_VERSION"

msg_info "Installing Docker Compose"
$STD apt-get install -y docker-compose-plugin
msg_ok "Installed Docker Compose"

msg_info "Installing SSH Server"
$STD apt-get install -y openssh-server
$STD systemctl enable ssh --now
msg_ok "Installed SSH Server"

msg_info "Installing Avahi (mDNS)"
$STD apt-get install -y avahi-daemon
$STD systemctl enable avahi-daemon --now
msg_ok "Installed Avahi"

MDNS_HOSTNAME="${HOSTNAME:-news}"
msg_info "Configuring hostname: $MDNS_HOSTNAME"
echo "$MDNS_HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$MDNS_HOSTNAME" 2>/dev/null || true
if ! grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  echo "127.0.1.1 $MDNS_HOSTNAME" >> /etc/hosts
else
  sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1 $MDNS_HOSTNAME/" /etc/hosts
fi
$STD systemctl restart avahi-daemon
msg_ok "Configured hostname: $MDNS_HOSTNAME"

GIT_REPO="${GIT_REPO:-https://github.com/EdmondStassen/Supervisory_relations_newsletter.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PROJECT_DIR="/opt/news_fetch"

msg_info "Cloning repository"
if [[ -d "$PROJECT_DIR/.git" ]]; then
  cd "$PROJECT_DIR"
  msg_info "Repository exists, fetching updates"
  git fetch --all
  git checkout "$GIT_BRANCH"
  git pull
  msg_ok "Repository updated"
else
  rm -rf "$PROJECT_DIR"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    msg_info "Cloning with GitHub token"
    git clone --branch "$GIT_BRANCH" \
      "https://x-access-token:${GITHUB_TOKEN}@github.com/EdmondStassen/Supervisory_relations_newsletter.git" \
      "$PROJECT_DIR"
  else
    msg_info "Cloning from public repository"
    git clone --branch "$GIT_BRANCH" "$GIT_REPO" "$PROJECT_DIR"
  fi
  msg_ok "Repository cloned"
fi

msg_info "Creating project directories"
mkdir -p "$PROJECT_DIR/logs"
msg_ok "Created project directories"

ENV_FILE="$PROJECT_DIR/.env"
msg_info "Writing environment file"
if [[ -f "$ENV_FILE" ]]; then
  cp -f "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
fi
cat > "$ENV_FILE" <<EOF
SMTP_PASSWORD=${SMTP_PASSWORD:-}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
EOF
chmod 0600 "$ENV_FILE"
msg_ok "Environment file written"

msg_info "Starting Docker Compose"
cd "$PROJECT_DIR"
docker compose --env-file "$ENV_FILE" up -d
msg_ok "Docker Compose started"

msg_info "Verifying deployment"
docker compose --env-file "$ENV_FILE" ps
msg_ok "Deployment verified"

msg_info "Installing cron"
$STD apt-get install -y cron
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
echo 'Europe/Amsterdam' > /etc/timezone

cat > /etc/cron.d/news_fetch <<'CRONEOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Update repo and restart container every weekday at 7:45 AM
45 7 * * 1-5 root cd /opt/news_fetch && git pull >> /opt/news_fetch/logs/git-update.log 2>&1 && docker compose --env-file /opt/news_fetch/.env restart >> /opt/news_fetch/logs/git-update.log 2>&1

# Run workflow every weekday at 8:00 AM
0 8 * * 1-5 root cd /opt/news_fetch && docker compose --env-file /opt/news_fetch/.env exec -T news_fetch python run_workflow.py >> /opt/news_fetch/logs/cron.log 2>&1
CRONEOF

chmod 0644 /etc/cron.d/news_fetch
$STD systemctl enable cron --now
msg_ok "Installed cron"

motd_ssh
customize
cleanup_lxc
