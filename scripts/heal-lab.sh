#!/bin/bash
# heal-lab.sh — restore all lab components to healthy baseline

# Refuse to run without known-good backups (Section 9.5); without them a heal cannot undo scenarios 1, 3, or 5
for f in /opt/surilab/suricata/config/suricata.yaml.bak /opt/surilab/fluent-bit/fluent-bit.conf.bak; do
  [ -f "$f" ] || { echo "[!] Missing backup: $f — create backups from a healthy lab first (Section 9.5)." >&2; exit 1; }
done

echo '[*] Stopping all containers...'
cd /opt/surilab && docker compose down

echo '[*] Restoring suricata.yaml from backup...'
cp /opt/surilab/suricata/config/suricata.yaml.bak \
   /opt/surilab/suricata/config/suricata.yaml

echo '[*] Restoring local.rules...'
[ -f /opt/surilab/suricata/rules/local.rules.bak ] && \
  mv /opt/surilab/suricata/rules/local.rules.bak \
     /opt/surilab/suricata/rules/local.rules

echo '[*] Restoring fluent-bit.conf from backup...'
cp /opt/surilab/fluent-bit/fluent-bit.conf.bak \
   /opt/surilab/fluent-bit/fluent-bit.conf
chmod 644 /opt/surilab/fluent-bit/fluent-bit.conf
mkdir -p /opt/surilab/fluent-bit/state

echo '[*] Fixing log directory permissions...'
chmod 755 /opt/surilab/suricata/logs
chown -R analyst:analyst /opt/surilab/suricata/logs   # matches PUID/PGID in docker-compose.yml

echo '[*] Starting lab in healthy state...'
docker compose up -d

echo '[+] Lab restored. Wait for Splunk to finish booting, then run validate-health.sh.'
