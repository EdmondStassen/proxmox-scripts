#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts
# Author: Edmond Stassen
# License: MIT
# Source: https://github.com/EdmondStassen/proxmox-scripts

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Updating Container OS"
$STD apt-get update
$STD apt-get -y upgrade
msg_ok "Updated Container OS"

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  sudo \
  mc \
  git \
  gpg \
  ca-certificates \
  jq
msg_ok "Installed Dependencies"

DOCKER_LATEST_VERSION=$(get_latest_github_release "moby/moby")

msg_info "Installing Docker $DOCKER_LATEST_VERSION"
DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
mkdir -p $(dirname $DOCKER_CONFIG_PATH)
cat > $DOCKER_CONFIG_PATH <<EOF
{
  "log-driver": "journald"
}
EOF
$STD sh <(curl -fsSL https://get.docker.com)
$STD systemctl enable --now docker
msg_ok "Installed Docker $DOCKER_LATEST_VERSION"

msg_info "Installing Docker Compose"
DOCKER_COMPOSE_VERSION=$(get_latest_github_release "docker/compose")
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
$STD curl -sSL https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
msg_ok "Installed Docker Compose $DOCKER_COMPOSE_VERSION"

# Optional: Portainer
read -r -p "Would you like to add Portainer? <y/N> " prompt
if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
  PORTAINER_LATEST_VERSION=$(get_latest_github_release "portainer/portainer")
  msg_info "Installing Portainer $PORTAINER_LATEST_VERSION"
  $STD docker volume create portainer_data
  $STD docker run -d \
    -p 8000:8000 \
    -p 9443:9443 \
    --name=portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
  msg_ok "Installed Portainer $PORTAINER_LATEST_VERSION"
fi

msg_info "Installing SSH Server"
$STD apt-get install -y openssh-server
$STD systemctl enable --now ssh
msg_ok "Installed SSH Server"

msg_info "Installing Avahi (mDNS)"
$STD apt-get install -y avahi-daemon
$STD systemctl enable --now avahi-daemon
msg_ok "Installed Avahi (mDNS)"

MDNS_HOSTNAME="${var_hostname:-news}"
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

# Git repository setup
GIT_REPO="${GIT_REPO:-https://github.com/EdmondStassen/Supervisory_relations_newsletter.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PROJECT_DIR="${PROJECT_DIR:-/opt/news_fetch}"

msg_info "Cloning repository"
if [[ -d "$PROJECT_DIR/.git" ]]; then
  cd "$PROJECT_DIR"
  $STD git fetch --all
  $STD git checkout "$GIT_BRANCH"
  $STD git pull
else
  rm -rf "$PROJECT_DIR"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    $STD git clone --branch "$GIT_BRANCH" \
      "https://x-access-token:${GITHUB_TOKEN}@github.com/EdmondStassen/Supervisory_relations_newsletter.git" \
      "$PROJECT_DIR"
  else
    $STD git clone --branch "$GIT_BRANCH" "$GIT_REPO" "$PROJECT_DIR"
  fi
fi
msg_ok "Repository cloned/updated"

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
$STD docker compose --env-file "$ENV_FILE" up -d
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
$STD systemctl enable --now cron
msg_ok "Installed cron"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
