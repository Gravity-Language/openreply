#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${1:-}"
if [[ -z "$SOURCE_DIR" || ! -f "${SOURCE_DIR}/compose.gcp.yml" ]]; then
  echo "Usage: sudo $0 /path/to/uploaded/openreply-deploy" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

install -d -m 0755 /opt/openreply/scripts/gcp
install -m 0644 "${SOURCE_DIR}/compose.gcp.yml" /opt/openreply/compose.gcp.yml
install -m 0644 "${SOURCE_DIR}/Caddyfile" /opt/openreply/Caddyfile
install -m 0755 "${SOURCE_DIR}/scripts/cron.sh" /opt/openreply/scripts/cron.sh
install -m 0755 "${SOURCE_DIR}/scripts/gcp/deploy.sh" /opt/openreply/scripts/gcp/deploy.sh
install -m 0755 "${SOURCE_DIR}/scripts/gcp/backup.sh" /opt/openreply/scripts/gcp/backup.sh
install -m 0755 "${SOURCE_DIR}/scripts/gcp/restore.sh" /opt/openreply/scripts/gcp/restore.sh
install -m 0644 "${SOURCE_DIR}/scripts/gcp/openreply-backup.service" /etc/systemd/system/openreply-backup.service
install -m 0644 "${SOURCE_DIR}/scripts/gcp/openreply-backup.timer" /etc/systemd/system/openreply-backup.timer

systemctl daemon-reload
systemctl enable --now openreply-backup.timer
echo "Installed OpenReply deployment files and backup timer."
