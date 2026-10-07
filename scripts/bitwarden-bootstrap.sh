#!/bin/bash
set -euxo pipefail

dnf update -y
dnf install -y amazon-ssm-agent docker docker-compose-plugin unzip libatomic libsecret ca-certificates tar gzip
systemctl enable --now amazon-ssm-agent
systemctl enable --now docker

if ! id -u bitwarden >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash bitwarden
fi

usermod -aG docker bitwarden
install -d -o bitwarden -g bitwarden -m 0700 /opt/bitwarden
chown -R bitwarden:bitwarden /opt/bitwarden

if ! command -v bwdc >/dev/null 2>&1; then
  curl -fsSL -o /tmp/bwdc.zip https://github.com/bitwarden/directory-connector/releases/download/v2026.9.0/bwdc-linux-2026.9.0.zip
  unzip -q /tmp/bwdc.zip -d /tmp/bwdc
  install -m 0755 /tmp/bwdc/bwdc /usr/local/bin/bwdc
  install -m 0644 /tmp/bwdc/dc_native.linux-x64-gnu.node /opt/bitwarden/dc_native.linux-x64-gnu.node
  chown root:root /usr/local/bin/bwdc
  chown bitwarden:bitwarden /opt/bitwarden/dc_native.linux-x64-gnu.node
fi
