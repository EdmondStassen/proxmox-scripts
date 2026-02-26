#!/usr/bin/env bash
set -Eeuo pipefail

# Copyright (c) 2021-2026 tteck
# Author: Edmond Stassen (based on tteck's community-scripts)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Proxmox Installer for news_fetch Docker LXC Container

# Workaround for SSH_CLIENT unbound variable
export SSH_CLIENT="${SSH_CLIENT:-}"

# Load community-scripts helpers
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Application configuration
APP="news-fetch"
var_tags="${var_tags:-docker;newsletter;news_fetch}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

# Custom install script path
export FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/main/install/news-fetch-install-simple.sh)"

# Initialize build environment
header_info "$APP"
variables
color
catch_errors

# Update script
update_script() {
  header_info
  check_container_storage
  check_container_resources

  msg_info "Updating Container OS"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Updated Container OS"

  msg_info "Updating Docker"
  $STD apt-get install --only-upgrade -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  msg_ok "Updated Docker"

  PROJECT_DIR="/opt/news_fetch"
  if [[ -d "$PROJECT_DIR" ]]; then
    msg_info "Updating news_fetch repository"
    cd "$PROJECT_DIR"
    $STD git pull
    $STD docker compose down
    $STD docker compose up -d
    msg_ok "Updated news_fetch"
  fi

  msg_ok "Update completed"
  exit
}

# Start installation
start
build_container
description
