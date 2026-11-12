#!/bin/bash
# validate-health.sh — confirm all lab components are operational
# Run as analyst (docker group) or with sudo
PASS=0; FAIL=0

check() {
  local desc="$1" cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo "  [PASS] $desc"; ((PASS++))
  else
    echo "  [FAIL] $desc"; ((FAIL++))
  fi
}

echo '=== Suricata ==='
check 'Container running' \
  "docker inspect -f '{{.State.Running}}' suricata | grep -q true"
check 'Rules loaded (>0)' \
  "docker logs suricata 2>&1 | grep -qE '[1-9][0-9]* rules successfully loaded'"
check 'Suricata version is 8.0.8' \
  "docker exec suricata suricata -V 2>&1 | grep -q 'version 8.0.8'"
check 'eve.json exists and is recent' \
  "[ \$(find /opt/surilab/suricata/logs/eve.json -mmin -5 2>/dev/null | wc -l) -gt 0 ]"

echo '=== Splunk ==='
check 'Splunk web reachable' \
  "curl -sL http://localhost:8000 | grep -q 'Splunk'"
check 'HEC endpoint healthy (plain HTTP)' \
  "curl -s http://localhost:8088/services/collector/health | grep -q '\"code\":17'"
check 'HEC accepts events for index=suricata' \
  "curl -s http://localhost:8088/services/collector/event -H 'Authorization: Splunk lab-hec-token-0000' -d '{\"event\":\"surilab health check\",\"index\":\"suricata\",\"sourcetype\":\"surilab:healthcheck\"}' | grep -q '\"code\":0'"

echo '=== Fluent Bit ==='
check 'Fluent Bit container running' \
  "docker inspect -f '{{.State.Running}}' fluent-bit | grep -q true"
check 'No HEC delivery errors (last 2 min)' \
  "docker inspect fluent-bit &>/dev/null && ! docker logs --since 2m fluent-bit 2>&1 | grep -qE 'http_status=4[0-9]{2}|\[error\]'"

echo ''
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && echo '[+] Lab is HEALTHY' || echo '[-] Lab has failures'
exit $FAIL
