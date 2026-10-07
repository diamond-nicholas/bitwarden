#!/bin/bash
set -euxo pipefail

dnf update -y
dnf install -y amazon-ssm-agent docker curl tar gzip ca-certificates
systemctl enable --now amazon-ssm-agent
systemctl enable --now docker

if ! id -u bitwarden >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash bitwarden
fi

usermod -aG docker bitwarden
install -d -o bitwarden -g bitwarden /opt/bitwarden
chown -R bitwarden:bitwarden /opt/bitwarden

if ! command -v bwdc >/dev/null 2>&1; then
  curl -fsSL https://github.com/bitwarden/directory-connector/releases/latest/download/bwdc-linux-x64.tar.gz \
    -o /tmp/bwdc.tar.gz
  tar -xzf /tmp/bwdc.tar.gz -C /opt/bitwarden
  install -m 0755 /opt/bitwarden/bwdc /usr/local/bin/bwdc
  chown root:root /usr/local/bin/bwdc
fi
