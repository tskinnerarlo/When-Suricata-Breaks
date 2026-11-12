#!/bin/bash
# surilab-build-check.sh — SuriLab 2026 build progress checklist
# Checks the VM against "When Suricata Breaks — VM Build Guide v11" and reports,
# section by section, which configuration steps are DONE and which are still TODO.
#
# Usage:   sudo bash surilab-build-check.sh [--active] [--no-color]
#
#   (default)   Read-only. Changes nothing in the lab. It does start two
#               throwaway containers (docker run --rm) to read the Suricata
#               version and test-load the config, and it saves a report in /tmp.
#   --active    Also runs the two tests that write data, both taken from the guide:
#               posts one HEC test event to index=suricata (sourcetype
#               surilab:healthcheck) and pings the ens34 gateway to fire the ICMP rule.
#
# Statuses:  [DONE] step complete      [TODO] step missing or wrong (fix shown)
#            [WARN] works, but differs from the guide or needs a look
#            [MANL] cannot be checked by a script; confirm by hand
#
# Exit code: 0 when there are no TODO items, 1 otherwise.

set -u

ACTIVE=false; COLOR=true
for a in "$@"; do
    case "$a" in
        --active)   ACTIVE=true ;;
        --no-color) COLOR=false ;;
        -h|--help)  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a (use --active, --no-color)" >&2; exit 2 ;;
    esac
done
[ -t 1 ] || COLOR=false

# ---- Values from the build guide ------------------------------------------------
LAB=/opt/surilab
IFACE=ens34
LAB_USER=analyst
SURI_IMG=jasonish/suricata:8.0.8
SURI_VER=8.0.8
SPLUNK_IMG=splunk/splunk:latest
FB_IMG=fluent/fluent-bit:5.0.8
HEC_TOKEN=lab-hec-token-0000
SPLUNK_UID=41812
YAML=$LAB/suricata/config/suricata.yaml
RULES=$LAB/suricata/rules/local.rules
FBCONF=$LAB/fluent-bit/fluent-bit.conf
COMPOSE=$LAB/docker-compose.yml
LOGS=$LAB/suricata/logs
SCRIPTS=$LAB/scripts
REPORT=/tmp/surilab-build-check-$(date +%Y%m%d-%H%M%S).txt

if $COLOR; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
else G=; R=; Y=; C=; B=; N=; fi

DONE=0; TODO=0; WARN=0; MANL=0
SECTION=""
TODO_LIST=(); WARN_LIST=(); MANL_LIST=()

sec()    { SECTION="$1"; printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }
ok()     { printf '  %s[DONE]%s %s\n' "$G" "$N" "$1"; DONE=$((DONE+1)); }
todo()   { printf '  %s[TODO]%s %s\n' "$R" "$N" "$1"; [ -n "${2:-}" ] && printf '         fix: %s\n' "$2"
           TODO=$((TODO+1)); TODO_LIST+=("$SECTION|$1|${2:-}"); }
warn()   { printf '  %s[WARN]%s %s\n' "$Y" "$N" "$1"; [ -n "${2:-}" ] && printf '         note: %s\n' "$2"
           WARN=$((WARN+1)); WARN_LIST+=("$SECTION|$1|${2:-}"); }
manual() { printf '  %s[MANL]%s %s\n' "$C" "$N" "$1"; MANL=$((MANL+1)); MANL_LIST+=("$SECTION|$1"); }
# chk "description" "fix" 'test command'   -> DONE or TODO
chk()    { if eval "$3" >/dev/null 2>&1; then ok "$1"; else todo "$1" "$2"; fi; }
# chkw: same, but a failure is only a WARN
chkw()   { if eval "$3" >/dev/null 2>&1; then ok "$1"; else warn "$1" "$2"; fi; }

T() { timeout "${TMO:-20}" "$@"; }
has() { command -v "$1" >/dev/null 2>&1; }
pkg() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
perm()  { stat -c %a "$1" 2>/dev/null; }
owner() { stat -c %U:%G "$1" 2>/dev/null; }
uidof() { stat -c %u:%g "$1" 2>/dev/null; }
running() { [ "$(T docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
# Print one service block from docker-compose.yml
svc() { awk -v s="$1" '
    $0 ~ "^[[:space:]]+" s ":[[:space:]]*$" && !f { match($0,/^[[:space:]]+/); ind=RLENGTH; f=1; next }
    f && NF { match($0,/^[[:space:]]*/); if (RLENGTH<=ind) exit }
    f { print }' "$COMPOSE" 2>/dev/null | sed 's/[[:space:]]#.*$//'; }
# First "- interface:" under af-packet in a suricata.yaml
afiface() { awk '/^af-packet:/{f=1;next} f && /^[^[:space:]#]/{exit}
    f && /^[[:space:]]*- interface:/{print $3; exit}' "$1" 2>/dev/null; }

main() {
printf '%sSuriLab 2026 — build progress check (Build Guide v11)%s\n' "$B" "$N"
printf 'Host: %s   Date: %s   Mode: %s\n' "$(hostname)" "$(date -u '+%Y-%m-%d %H:%M UTC')" \
    "$($ACTIVE && echo 'active (writes a test event, sends pings)' || echo 'read-only')"

IS_ROOT=false; [ "$(id -u)" -eq 0 ] && IS_ROOT=true
$IS_ROOT || printf '%sNot running as root: some checks (Splunk files, sudoers, logs) may report TODO wrongly. Re-run with sudo.%s\n' "$Y" "$N"

DOCKER_OK=false
has docker && T docker info >/dev/null 2>&1 && DOCKER_OK=true

# ---- Is a fault currently injected? ---------------------------------------------
FAULTS=""
grep -q 'THIS IS NOT YAML' "$YAML" 2>/dev/null && FAULTS="$FAULTS 1(config corrupt)"
[ ! -f "$RULES" ] && [ -f "$RULES.bak" ] && FAULTS="$FAULTS 2(rules missing)"
[ "$(afiface "$YAML")" = eth99 ] && FAULTS="$FAULTS 3(wrong interface)"
[ -d "$LOGS" ] && [ "$(perm "$LOGS")" = 0 ] && FAULTS="$FAULTS 4(log permissions)"
grep -q 'WRONG-TOKEN' "$FBCONF" 2>/dev/null && FAULTS="$FAULTS 5(bad HEC token)"
if [ -n "$FAULTS" ]; then
    printf '\n%s!! An injected fault looks active: scenario%s.%s\n' "$R" "$FAULTS" "$N"
    printf '   Checks on that component will show TODO. Run: sudo %s/heal-lab.sh  then re-run this script.\n' "$SCRIPTS"
fi

# =================================================================================
sec "3. VM specifications and accounts"
. /etc/os-release 2>/dev/null
chk "Ubuntu 24.04 LTS (found: ${PRETTY_NAME:-unknown})" "Guide 3.1 requires Ubuntu 24.04 LTS Desktop" \
    '[ "${VERSION_ID:-}" = 24.04 ]'
chkw "4 vCPUs (found: $(nproc))" "Guide 3.1: 4 vCPUs (2 processors x 2 cores)" '[ "$(nproc)" -eq 4 ]'
MEMG=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
chkw "8 GB RAM (found: ${MEMG} GB)" "Guide 3.1: 8192 MB" \
    'awk "/MemTotal/{exit !(\$2>=7400000 && \$2<=8500000)}" /proc/meminfo'
chk "Host-only adapter $IFACE exists" "VM Settings > Add > Network Adapter > Host-only (vmnet1) (4.1). Confirm the name with: ip -br link" \
    "ip link show $IFACE"
chkw "$IFACE is UP" "Bring it up; Suricata captures and tcpreplay replays on it (5.3)" \
    "ip -br link show $IFACE | grep -qw UP"
chk "User $LAB_USER exists" "Create it during Ubuntu install (4.2)" "id $LAB_USER"
if $IS_ROOT; then
    chk "$LAB_USER has passwordless sudo" \
        "echo '$LAB_USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$LAB_USER && sudo chmod 440 /etc/sudoers.d/$LAB_USER (3.2)" \
        "sudo -l -U $LAB_USER | grep -q NOPASSWD"
else manual "$LAB_USER has passwordless sudo via sudoers.d (3.2) — needs root to check"; fi
chkw "Installation account idsadmin exists" "Listed in 3.2; ignore if you built without it" "id idsadmin"
TZ_NOW=$(timedatectl show -p Timezone --value 2>/dev/null)
chk "Timezone is UTC (found: ${TZ_NOW:-unknown})" "sudo timedatectl set-timezone UTC (4.2)" \
    '[ "$TZ_NOW" = UTC ] || [ "$TZ_NOW" = Etc/UTC ]'
chk "Auto-login is OFF" "Settings > Users > Automatic Login off, or remove AutomaticLoginEnable from /etc/gdm3/custom.conf (4.2)" \
    "! grep -Eiq '^[[:space:]]*AutomaticLoginEnable[[:space:]]*=[[:space:]]*true' /etc/gdm3/custom.conf"

# =================================================================================
sec "4.3 First boot configuration"
chk "snapd removed" "sudo snap remove --purge firefox; sudo apt purge snapd -y; sudo apt autoremove --purge -y" "! pkg snapd"
MISSING=""
for p in curl wget git vim nano net-tools iproute2 iputils-ping tcpdump wireshark-common tshark tcpreplay \
         jq python3 python3-pip htop tree unzip ca-certificates gnupg lsb-release software-properties-common; do
    pkg "$p" || MISSING="$MISSING $p"
done
if [ -z "$MISSING" ]; then ok "All 22 essential tool packages installed"
else todo "Essential packages missing:$MISSING" "sudo apt install -y$MISSING"; fi
chk "tcpreplay runs on the host" "sudo apt install -y tcpreplay" "tcpreplay --version"
chk "$LAB_USER is in the wireshark group" "sudo usermod -aG wireshark $LAB_USER" "id -nG $LAB_USER | grep -qw wireshark"
chkw "Non-root capture enabled (dumpcap group is wireshark)" "sudo dpkg-reconfigure wireshark-common  and select Yes" \
    '[ "$(stat -c %G /usr/bin/dumpcap)" = wireshark ]'
chk "Mozilla APT repository and pin configured" "Follow the Firefox block in 4.3 (mozilla.list + preferences.d/mozilla)" \
    "[ -f /etc/apt/sources.list.d/mozilla.list ] && [ -f /etc/apt/preferences.d/mozilla ]"
chk "Firefox installed as a .deb at /usr/bin/firefox" "sudo apt update && sudo apt install -y firefox (after adding the Mozilla repo)" \
    "pkg firefox && [ -x /usr/bin/firefox ] && ! dpkg-query -W -f='\${Version}' firefox | grep -q snap"
chk "Firefox comes from packages.mozilla.org" "apt policy firefox must show packages.mozilla.org as the installed source" \
    "apt-cache policy firefox | grep -q packages.mozilla.org"

# =================================================================================
sec "5. Docker installation"
MISSING=""
for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do pkg "$p" || MISSING="$MISSING $p"; done
if [ -z "$MISSING" ]; then ok "Docker Engine packages installed"
else todo "Docker packages missing:$MISSING" "Follow 5.1 (Docker APT repo, then apt install)"; fi
chk "docker --version works" "Install Docker Engine (5.1)" "docker --version"
chk "docker compose version works" "sudo apt install -y docker-compose-plugin" "docker compose version"
chk "Docker service is running and enabled at boot" "sudo systemctl enable --now docker" \
    "systemctl is-active docker && systemctl is-enabled docker"
chk "$LAB_USER is in the docker group" "sudo usermod -aG docker $LAB_USER, then log out and back in" \
    "id -nG $LAB_USER | grep -qw docker"
if $IS_ROOT; then
    chk "docker ps works as $LAB_USER without sudo" "Add $LAB_USER to the docker group and re-login (5.1)" \
        "T sudo -n -u $LAB_USER docker ps"
    manual "Open $LAB_USER desktop sessions were re-logged-in after the docker group change (run 'docker ps' in a terminal as $LAB_USER)"
else
    chk "docker ps works for the current user without sudo" "Log out and back in after the docker group change (5.1)" "T docker ps"
fi

sec "5.2 Container images"
if $DOCKER_OK; then
    chk "Image $SURI_IMG present" "docker pull $SURI_IMG (NAT adapter must be connected)" "T docker image inspect $SURI_IMG"
    chk "Image $SPLUNK_IMG present" "docker pull $SPLUNK_IMG" "T docker image inspect $SPLUNK_IMG"
    chk "Image $FB_IMG present" "docker pull $FB_IMG" "T docker image inspect $FB_IMG"
    if T docker image inspect "$SURI_IMG" >/dev/null 2>&1; then
        chk "Suricata image reports version $SURI_VER" "Re-pull the pinned tag: docker pull $SURI_IMG" \
            "TMO=60 T docker run --rm --entrypoint suricata $SURI_IMG -V 2>&1 | grep -q 'version $SURI_VER'"
    fi
    chkw "No retired images (Filebeat, tcpreplay container, suricata:latest)" \
        "Not used since v5/v6; remove with docker rmi to shrink the OVA" \
        "! docker images --format '{{.Repository}}:{{.Tag}}' | grep -Eq 'filebeat|tcpreplay|jasonish/suricata:latest'"
else
    todo "Docker daemon not reachable — image checks skipped" "Start Docker (sudo systemctl start docker) and re-run with sudo"
fi

sec "5.4 Docker network"
if $DOCKER_OK; then
    chk "Network lab-net exists" "docker network create --driver bridge --subnet 172.20.0.0/24 lab-net" "T docker network inspect lab-net"
    chk "lab-net is a bridge on 172.20.0.0/24" "docker network rm lab-net, then recreate with --driver bridge --subnet 172.20.0.0/24" \
        "[ \"\$(docker network inspect -f '{{.Driver}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' lab-net)\" = 'bridge 172.20.0.0/24' ]"
else todo "Docker daemon not reachable — network check skipped" ""; fi

# =================================================================================
sec "6. Directory structure and ownership"
MISSING=""
for d in suricata/config suricata/rules suricata/logs splunk/data splunk/etc fluent-bit/state scripts pcaps; do
    [ -d "$LAB/$d" ] || MISSING="$MISSING $d"
done
if [ -z "$MISSING" ]; then ok "All 8 directories exist under $LAB"
else todo "Missing under $LAB:$MISSING" "sudo mkdir -p $LAB/{suricata/{config,rules,logs},splunk/{data,etc},fluent-bit/state,scripts,pcaps}"; fi
chk "$LAB owned by $LAB_USER" "sudo chown -R $LAB_USER:$LAB_USER $LAB, then re-apply the Splunk chown below" \
    "[ \"\$(owner $LAB)\" = $LAB_USER:$LAB_USER ]"
chk "splunk/data and splunk/etc owned by UID $SPLUNK_UID" "sudo chown -R $SPLUNK_UID:$SPLUNK_UID $LAB/splunk/data $LAB/splunk/etc" \
    "[ \"\$(uidof $LAB/splunk/data)\" = $SPLUNK_UID:$SPLUNK_UID ] && [ \"\$(uidof $LAB/splunk/etc)\" = $SPLUNK_UID:$SPLUNK_UID ]"
chk "suricata/logs owned by $LAB_USER, mode 755" "sudo chown -R $LAB_USER:$LAB_USER $LOGS && sudo chmod 755 $LOGS" \
    "[ \"\$(owner $LOGS)\" = $LAB_USER:$LAB_USER ] && [ \"\$(perm $LOGS)\" = 755 ]"

sec "6.1 Lab PCAP"
PCAP=$LAB/pcaps/lab-traffic.pcap
if [ -s "$PCAP" ]; then
    ok "pcaps/lab-traffic.pcap exists"
    NICMP=$(tcpdump -nn -r "$PCAP" icmp 2>/dev/null | wc -l)
    chk "PCAP contains ICMP packets (found: $NICMP)" "Re-create it with the capture block in 6.1" "[ $NICMP -gt 0 ]"
    chk "PCAP contains HTTP requests with a curl User-Agent" "Re-create it with the capture block in 6.1 (the two curl commands must succeed)" \
        "tcpdump -nn -A -r $PCAP 'tcp port 80' 2>/dev/null | grep -q 'User-Agent: curl'"
else
    todo "pcaps/lab-traffic.pcap does not exist" "Create it with the capture block in Section 6.1 (NAT adapter ens33 must be connected)"
fi

# =================================================================================
sec "7.1 suricata.yaml"
if [ -f "$YAML" ]; then
    LINES=$(wc -l < "$YAML"); AF=$(afiface "$YAML")
    chk "Full $SURI_VER default config, not the override snippet ($LINES lines, expect ~2,400)" \
        "docker run --rm --entrypoint cat $SURI_IMG /etc/suricata/suricata.yaml > $YAML, then redo the sed edits (7.1)" \
        "[ $LINES -ge 2000 ]"
    chk "af-packet capture interface is $IFACE (found: ${AF:-none})" \
        "sed -i '0,/^\\( *\\)- interface: .*/s//\\1- interface: $IFACE/' $YAML" "[ \"$AF\" = $IFACE ]"
    chk "rule-files loads /etc/suricata/rules/local.rules" \
        "sed -i 's#^\\( *\\)- suricata.rules#\\1- /etc/suricata/rules/local.rules#' $YAML" \
        "awk '/^rule-files:/{f=1;next} f&&/^[^[:space:]#]/{exit} f' $YAML | grep -Eq '^[[:space:]]*-[[:space:]]*/etc/suricata/rules/local.rules'"
    chk "No corruption marker in the file" "Remove the 'THIS IS NOT YAML' line (scenario 1) or run heal-lab.sh" \
        "! grep -q 'THIS IS NOT YAML' $YAML"
else
    todo "suricata.yaml does not exist" "docker run --rm --entrypoint cat $SURI_IMG /etc/suricata/suricata.yaml > $YAML (7.1)"
fi

sec "7.2 local.rules"
if [ -f "$RULES" ]; then
    NR=$(grep -Evc '^[[:space:]]*(#|$)' "$RULES")
    chk "Both lab rules present (sid 9000001 ICMP, sid 9000002 curl User-Agent)" "Re-create the file from 7.2" \
        "grep -q 'sid:9000001' $RULES && grep -q 'sid:9000002' $RULES"
    chk "Exactly 2 rule lines, each on one line (found: $NR)" "Each rule must be a single line (7.2)" "[ $NR -eq 2 ]"
    chk "local.rules is mode 644" "chmod 644 $RULES" "[ \"\$(perm $RULES)\" = 644 ]"
else
    todo "local.rules does not exist" "Create $RULES from 7.2 (if local.rules.bak exists, scenario 2 is active: run heal-lab.sh)"
fi

if $DOCKER_OK && [ -f "$YAML" ] && [ -f "$RULES" ] && T docker image inspect "$SURI_IMG" >/dev/null 2>&1; then
    # Read-only mounts and a direct entrypoint, so the image cannot change file ownership on the host
    TOUT=$(TMO=120 T docker run --rm --entrypoint suricata \
        -v "$YAML":/etc/suricata/suricata.yaml:ro -v "$LAB/suricata/rules":/etc/suricata/rules:ro \
        "$SURI_IMG" -T -c /etc/suricata/suricata.yaml -v 2>&1)
    if echo "$TOUT" | grep -q 'successfully loaded' && echo "$TOUT" | grep -q '2 rules successfully loaded'; then
        ok "Config test (suricata -T) passes with 2 rules loaded"
    else
        todo "Config test (suricata -T) failed or did not load 2 rules" \
             "Last output: $(echo "$TOUT" | grep -v '^$' | tail -2 | tr '\n' ' ' | cut -c1-220)"
    fi
else
    todo "Config test (suricata -T) not run — needs Docker, the image, suricata.yaml and local.rules" ""
fi

sec "7.3 fluent-bit.conf"
if [ -f "$FBCONF" ]; then
    chk "Tails /var/log/suricata/eve.json with the json parser" "Re-create the [INPUT] section from 7.3" \
        "grep -Eq '^ +Path +/var/log/suricata/eve.json' $FBCONF && grep -Eq '^ +Parser +json' $FBCONF"
    chk "Splunk output: Host splunk, Port 8088, TLS Off" "Re-create the [OUTPUT] section from 7.3" \
        "grep -Eq '^ +Name +splunk' $FBCONF && grep -Eq '^ +Host +splunk' $FBCONF && grep -Eq '^ +Port +8088' $FBCONF && grep -Eiq '^ +TLS +Off' $FBCONF"
    chk "Splunk_Token is $HEC_TOKEN" "Set Splunk_Token $HEC_TOKEN (WRONG-TOKEN means scenario 5 is active: run heal-lab.sh)" \
        "grep -Eq '^ +Splunk_Token +$HEC_TOKEN[[:space:]]*$' $FBCONF"
    chk "Event_Index suricata, Retry_Limit False" "Add the keys to [OUTPUT] (7.3)" \
        "grep -Eq '^ +Event_Index +suricata' $FBCONF && grep -Eiq '^ +Retry_Limit +False' $FBCONF"
    FBST=$(awk '/^ +Event_Sourcetype/{print $2}' "$FBCONF")
    CIMAPP=$LAB/splunk/etc/apps/surilab_suricata_cim
    if [ "$FBST" = suricata ]; then
        ok "Event_Sourcetype is suricata (CIM mapping)"
        chk "CIM mapping app installed (props, eventtypes, tags, default.meta)" "sudo bash install-suricata-cim.sh" \
            "[ -f $CIMAPP/default/props.conf ] && [ -f $CIMAPP/default/eventtypes.conf ] && [ -f $CIMAPP/default/tags.conf ] && [ -f $CIMAPP/metadata/default.meta ]"
        chk "CIM mapping app owned by UID $SPLUNK_UID" "sudo chown -R $SPLUNK_UID:$SPLUNK_UID $CIMAPP" "[ \"\$(uidof $CIMAPP/default/props.conf)\" = $SPLUNK_UID:$SPLUNK_UID ]"
        [ -f "$FBCONF.bak" ] && chk "fluent-bit.conf.bak also uses sourcetype suricata (heal-lab.sh restores from it)" \
            "sudo sed -i -E 's/^([[:space:]]+Event_Sourcetype[[:space:]]+).*/\\1suricata/' $FBCONF.bak" "grep -Eq '^ +Event_Sourcetype +suricata' $FBCONF.bak"
    elif [ "$FBST" = _json ]; then
        todo "Event_Sourcetype is still _json" "v10 uses sourcetype suricata with the CIM mapping app: sudo bash install-suricata-cim.sh (10.4)"
    else
        todo "Event_Sourcetype is '${FBST:-missing}'" "Set Event_Sourcetype to suricata (7.3) and install the CIM app (10.4)"
    fi
    chk "Indentation is strict: 4 spaces, no tabs, blank lines truly empty" \
        "sed -i -E 's/^[[:space:]]+\$//; s/^[[:space:]]+/    /' $FBCONF" \
        "! grep -nEv '^(\$|\\[[A-Z]+\\]\$|#|    [^[:space:]])' $FBCONF"
    chk "fluent-bit.conf is mode 644" "chmod 644 $FBCONF" "[ \"\$(perm $FBCONF)\" = 644 ]"
else
    todo "fluent-bit.conf does not exist" "Create $FBCONF from 7.3"
fi

# =================================================================================
sec "8. docker-compose.yml"
if [ -f "$COMPOSE" ]; then
    S=$(svc suricata); P=$(svc splunk); F=$(svc fluent-bit)
    AUID=$(id -u $LAB_USER 2>/dev/null || echo 1000); AGID=$(id -g $LAB_USER 2>/dev/null || echo 1000)
    if $DOCKER_OK; then chk "File parses (docker compose config)" "Fix the YAML errors shown by: cd $LAB && docker compose config" \
        "cd $LAB && T docker compose config -q"; fi
    chk "Obsolete top-level 'version:' key removed" "Delete the version: line (v8)" "! grep -Eq '^version:' $COMPOSE"
    chk "lab-net declared as an external network" "networks: / lab-net: / external: true" \
        "grep -A3 -E '^networks:' $COMPOSE | grep -Eq 'external:[[:space:]]*true'"
    chk "suricata: image pinned to $SURI_IMG" "Set image: $SURI_IMG (not :latest)" "echo \"\$S\" | grep -Eq 'image:[[:space:]]*$SURI_IMG[[:space:]]*\$'"
    chk "suricata: network_mode host, restart unless-stopped" "Add network_mode: host and restart: unless-stopped" \
        "echo \"\$S\" | grep -Eq 'network_mode:[[:space:]]*\"?host' && echo \"\$S\" | grep -q 'unless-stopped'"
    chk "suricata: PUID=$AUID and PGID=$AGID (match $LAB_USER)" \
        "Add under environment:  - PUID=$AUID  and  - PGID=$AGID  (v8; image user 998 cannot write the logs directory)" \
        "echo \"\$S\" | grep -Eq 'PUID=$AUID[[:space:]]*\$' && echo \"\$S\" | grep -Eq 'PGID=$AGID[[:space:]]*\$'"
    chk "suricata: caps NET_ADMIN, NET_RAW, SYS_NICE" "Add the three cap_add entries" \
        "echo \"\$S\" | grep -q NET_ADMIN && echo \"\$S\" | grep -q NET_RAW && echo \"\$S\" | grep -q SYS_NICE"
    chk "suricata: config, rules and logs volumes mounted" "Add the three volume lines from Section 8" \
        "echo \"\$S\" | grep -q '$YAML:/etc/suricata/suricata.yaml' && echo \"\$S\" | grep -q '$LAB/suricata/rules:/etc/suricata/rules' && echo \"\$S\" | grep -q '$LOGS:/var/log/suricata'"
    chk "suricata: no :ro on the config and rules mounts" "Remove :ro from both lines (v8; the entrypoint aborts when it cannot chown them)" \
        "! echo \"\$S\" | grep -Eq '/etc/suricata/(suricata.yaml|rules):ro'"
    chk "suricata: command has --af-packet and -v" "command: [\"-c\", \"/etc/suricata/suricata.yaml\", \"--af-packet\", \"-v\"]" \
        "echo \"\$S\" | grep -E 'command:' | grep -q -- '--af-packet' && echo \"\$S\" | grep -E 'command:' | grep -Eq '\"-v\"|[[:space:]]-v([[:space:]]|\$)'"
    chk "splunk: image $SPLUNK_IMG, ports 8000 and 8088 published" "Set image and both port mappings (Section 8)" \
        "echo \"\$P\" | grep -q 'image:[[:space:]]*$SPLUNK_IMG' && echo \"\$P\" | grep -q '8000:8000' && echo \"\$P\" | grep -q '8088:8088'"
    chk "splunk: license variables (SPLUNK_START_ARGS and SPLUNK_GENERAL_TERMS)" \
        "Add SPLUNK_START_ARGS=--accept-license and SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com" \
        "echo \"\$P\" | grep -q 'SPLUNK_START_ARGS=--accept-license' && echo \"\$P\" | grep -q 'SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com'"
    chk "splunk: SPLUNK_HEC_SSL=false" "Add - SPLUNK_HEC_SSL=false (HEC must answer on plain HTTP)" "echo \"\$P\" | grep -Eq 'SPLUNK_HEC_SSL=false'"
    chk "splunk: SPLUNK_HEC_TOKEN=$HEC_TOKEN and SPLUNK_PASSWORD set" "Add both environment lines (Section 8)" \
        "echo \"\$P\" | grep -q 'SPLUNK_HEC_TOKEN=$HEC_TOKEN' && echo \"\$P\" | grep -Eq 'SPLUNK_PASSWORD=.+'"
    chk "splunk: data and etc volumes mounted, on lab-net" "Add the two volume lines and networks: - lab-net" \
        "echo \"\$P\" | grep -q '$LAB/splunk/data:/opt/splunk/var' && echo \"\$P\" | grep -q '$LAB/splunk/etc:/opt/splunk/etc' && echo \"\$P\" | grep -q 'lab-net'"
    chk "fluent-bit: image pinned to $FB_IMG" "Set image: $FB_IMG" "echo \"\$F\" | grep -Eq 'image:[[:space:]]*$FB_IMG[[:space:]]*\$'"
    chk "fluent-bit: conf (ro), state, and suricata logs (ro) mounted" "Add the three volume lines from Section 8" \
        "echo \"\$F\" | grep -q '$FBCONF:/fluent-bit/etc/fluent-bit.conf:ro' && echo \"\$F\" | grep -q '$LAB/fluent-bit/state:/fluent-bit/state' && echo \"\$F\" | grep -q '$LOGS:/var/log/suricata:ro'"
    chk "fluent-bit: on lab-net, depends_on splunk" "Add networks: - lab-net and depends_on: - splunk" \
        "echo \"\$F\" | grep -q 'lab-net' && echo \"\$F\" | grep -A2 'depends_on' | grep -q splunk"
else
    todo "docker-compose.yml does not exist" "Save the file from Section 8 as $COMPOSE"
fi

# =================================================================================
sec "9. Lab control scripts"
for s in inject-fault.sh heal-lab.sh validate-health.sh install-cron-wrappers.sh; do
    chk "$s exists, is executable, and passes a syntax check" "Create $SCRIPTS/$s from Section 9, then chmod +x $SCRIPTS/*.sh" \
        "[ -x $SCRIPTS/$s ] && bash -n $SCRIPTS/$s"
done
chk "inject-fault.sh is the cron-compatible version (--quiet, --dry-run, --no-restart, --log)" "Replace with the script in 9.1" \
    "grep -q -- '--quiet' $SCRIPTS/inject-fault.sh && grep -q -- '--dry-run' $SCRIPTS/inject-fault.sh && grep -q -- '--no-restart' $SCRIPTS/inject-fault.sh && grep -q -- '--log' $SCRIPTS/inject-fault.sh"
chk "inject-fault.sh targets fluent-bit.conf and rewrites any interface name (scenario 3)" "Replace with the script in 9.1" \
    "grep -q 'fluent-bit.conf' $SCRIPTS/inject-fault.sh && grep -q 'eth99' $SCRIPTS/inject-fault.sh && ! grep -qi filebeat $SCRIPTS/inject-fault.sh"
chk "heal-lab.sh refuses to run without .bak backups (v8)" "Replace with the script in 9.4" "grep -q 'Missing backup' $SCRIPTS/heal-lab.sh"
chk "validate-health.sh posts a test event to index=suricata (v8)" "Replace with the script in 9.5" \
    "grep -q 'surilab:healthcheck' $SCRIPTS/validate-health.sh && grep -q 'version $SURI_VER' $SCRIPTS/validate-health.sh"

sec "9.2-9.3 Cron wrappers, schedule, log rotation"
MISSING=""; BADPERM=""
for w in cron-fault-s1.sh cron-fault-s2.sh cron-fault-s3.sh cron-fault-s4.sh cron-fault-s5.sh cron-fault-random.sh; do
    if [ ! -f "$SCRIPTS/$w" ]; then MISSING="$MISSING $w"
    elif [ "$(owner "$SCRIPTS/$w")" != root:root ] || [ "$(perm "$SCRIPTS/$w")" != 755 ]; then BADPERM="$BADPERM $w"; fi
done
if [ -n "$MISSING" ]; then todo "Cron wrappers missing:$MISSING" "sudo bash $SCRIPTS/install-cron-wrappers.sh"
elif [ -n "$BADPERM" ]; then todo "Cron wrappers not root:root mode 755:$BADPERM" "sudo bash $SCRIPTS/install-cron-wrappers.sh"
else ok "All 6 cron wrappers installed (root:root, 755)"; fi
chk "Wrappers call inject-fault.sh with --quiet" "Regenerate: sudo bash $SCRIPTS/install-cron-wrappers.sh" \
    "grep -q 'inject-fault.sh 3 --quiet' $SCRIPTS/cron-fault-s3.sh && grep -q 'inject-fault.sh 0 --quiet' $SCRIPTS/cron-fault-random.sh"
chk "surilab.cron and surilab.logrotate saved in scripts/" "Create both files from 9.3" \
    "[ -f $SCRIPTS/surilab.cron ] && [ -f $SCRIPTS/surilab.logrotate ]"
chk "/etc/cron.d/surilab installed (root:root, 644)" \
    "sudo cp $SCRIPTS/surilab.cron /etc/cron.d/surilab && sudo chown root:root /etc/cron.d/surilab && sudo chmod 644 /etc/cron.d/surilab" \
    "[ \"\$(owner /etc/cron.d/surilab)\" = root:root ] && [ \"\$(perm /etc/cron.d/surilab)\" = 644 ]"
if [ -f /etc/cron.d/surilab ]; then
    chk "/etc/cron.d/surilab ends with a newline" "echo >> /etc/cron.d/surilab (cron ignores an unterminated last line)" \
        "[ -z \"\$(tail -c1 /etc/cron.d/surilab)\" ]"
    NACT=$(grep -Ec '^[[:space:]]*[0-9*]' /etc/cron.d/surilab)
    if [ "$NACT" -gt 0 ]; then ok "Schedule has $NACT active entr$([ "$NACT" -eq 1 ] && echo y || echo ies)"
    else warn "No schedule option is uncommented in /etc/cron.d/surilab" "Uncomment Option A, B or C (9.3) if you want scheduled faults; leave as is to inject by hand"; fi
fi
chk "/etc/logrotate.d/surilab installed and valid" \
    "sudo cp $SCRIPTS/surilab.logrotate /etc/logrotate.d/surilab && sudo logrotate -d /etc/logrotate.d/surilab" \
    "[ -f /etc/logrotate.d/surilab ] && logrotate -d /etc/logrotate.d/surilab"
chk "/var/log/surilab exists" "sudo mkdir -p /var/log/surilab (install-cron-wrappers.sh creates it)" "[ -d /var/log/surilab ]"

sec "9.6 Scheduled traffic replay"
chk "/etc/cron.d/surilab-traffic replays the PCAP every 5 minutes" "Create it with the block in 9.6, or run install-v10-additions.sh" \
    "grep -Eq '^\*/5 .*tcpreplay --intf1=$IFACE .*lab-traffic.pcap' /etc/cron.d/surilab-traffic && [ \"\$(perm /etc/cron.d/surilab-traffic)\" = 644 ]"
chkw "Replay has run (tcpreplay.log has output)" "Appears after the next five-minute mark" "[ -s /var/log/surilab/tcpreplay.log ]"

sec "9.7 Desktop launchers"
DESK=$(getent passwd $LAB_USER | cut -d: -f6)/Desktop
chk "desktop-break.sh and desktop-heal.sh exist, executable, valid syntax" "Create them with the block in 9.7, or run install-v10-additions.sh" \
    "[ -x $SCRIPTS/desktop-break.sh ] && [ -x $SCRIPTS/desktop-heal.sh ] && bash -n $SCRIPTS/desktop-break.sh && bash -n $SCRIPTS/desktop-heal.sh"
chk "Break the Lab uses the shuffled deck and resets first" "Replace desktop-break.sh with the version in 9.7" \
    "grep -q 'shuf -i 1-5' $SCRIPTS/desktop-break.sh && grep -q 'heal-lab.sh' $SCRIPTS/desktop-break.sh"
for f in break-lab heal-lab lab-guide; do
    chk "Desktop icon $f.desktop exists and is executable" "Create it with the block in 9.7 / 9.8, as $LAB_USER in the desktop session" "[ -x $DESK/$f.desktop ]"
done
chk "Reset icon is named 'Reset the Lab'" "sed -i 's/^Name=.*/Name=Reset the Lab/' $DESK/heal-lab.desktop" "grep -q '^Name=Reset the Lab' $DESK/heal-lab.desktop"
manual "Desktop icons are trusted (no 'Allow Launching' prompt) and each one launches when double-clicked"
manual "Five clicks of Break the Lab give five different scenarios (check /var/log/surilab/inject-fault.log)"

sec "9.8 Student Lab Guide"
chk "apache2 installed, running, and enabled at boot" "sudo apt install -y apache2 && sudo systemctl enable --now apache2 (NAT must be connected)" \
    "pkg apache2 && systemctl is-active apache2 && systemctl is-enabled apache2"
chk "Apache listens on 127.0.0.1 only" "sudo sed -i 's/^Listen 80\$/Listen 127.0.0.1:80/' /etc/apache2/ports.conf && sudo systemctl restart apache2" \
    "grep -q '^Listen 127.0.0.1:80' /etc/apache2/ports.conf"
chk "http://localhost/ serves the Student Lab Guide" "sudo cp SuriLab-2026_Student-Lab-Guide.html /var/www/html/index.html" \
    "T curl -s http://localhost/ | grep -q 'When Suricata Breaks — Student Lab Guide'"
manual "Firefox bookmarks: Splunk and the Student Lab Guide; guide copy buttons and worksheet saving work"

sec "9.5 Known-good backups"
chk "suricata.yaml.bak exists" "After validate-health.sh shows 0 failures: cp $YAML $YAML.bak" "[ -f $YAML.bak ]"
chk "fluent-bit.conf.bak exists, mode 644" "After a clean validate-health.sh: cp $FBCONF $FBCONF.bak && chmod 644 $FBCONF.bak" \
    "[ -f $FBCONF.bak ] && [ \"\$(perm $FBCONF.bak)\" = 644 ]"
if [ -f "$YAML.bak" ]; then
    chk "suricata.yaml.bak is a healthy baseline (full file, $IFACE, no corruption)" \
        "Heal the lab, confirm validate-health.sh passes, then re-take the backup (9.5)" \
        "[ \$(wc -l < $YAML.bak) -ge 2000 ] && [ \"\$(afiface $YAML.bak)\" = $IFACE ] && ! grep -q 'THIS IS NOT YAML' $YAML.bak"
    [ -f "$YAML" ] && chkw "suricata.yaml matches its backup" \
        "They differ: a fault is active, or the config changed after the backup. Re-take the backup if the change was intended" "cmp -s $YAML $YAML.bak"
fi
if [ -f "$FBCONF.bak" ]; then
    chk "fluent-bit.conf.bak holds the correct HEC token" "Re-take the backup from a healthy fluent-bit.conf" "grep -q '$HEC_TOKEN' $FBCONF.bak"
    [ -f "$FBCONF" ] && chkw "fluent-bit.conf matches its backup" \
        "They differ: a fault is active, or the config changed after the backup" "cmp -s $FBCONF $FBCONF.bak"
fi

# =================================================================================
sec "Runtime: containers (Sections 8, 13)"
SPLUNK_UP=false
if $DOCKER_OK; then
    for c in suricata splunk fluent-bit; do
        ST=$(T docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo absent)
        chk "Container $c is running (status: $ST)" "cd $LAB && docker compose up -d   then: docker logs $c" "running $c"
    done
    running splunk && SPLUNK_UP=true
    if running suricata; then
        RC=$(docker inspect -f '{{.RestartCount}}' suricata 2>/dev/null)
        chk "suricata RestartCount is 0 (found: $RC)" "It has crash-looped: check docker logs suricata; then cd $LAB && docker compose up -d --force-recreate suricata" "[ \"$RC\" = 0 ]"
        SLOG=$(T docker logs suricata 2>&1 | grep -E 'rules successfully loaded' | tail -1)
        chk "docker logs suricata shows \"2 rules successfully loaded\"" "Needs -v in the compose command and a valid local.rules (7.2, 8)" \
            "echo \"\$SLOG\" | grep -Eq '(^|[^0-9])2 rules successfully loaded'"
        chk "Running Suricata reports version $SURI_VER" "Pin image: $SURI_IMG in docker-compose.yml and recreate" \
            "T docker exec suricata suricata -V 2>&1 | grep -q 'version $SURI_VER'"
        chk "Running Suricata captures on $IFACE" "Fix the af-packet interface in suricata.yaml and restart" \
            "T docker logs suricata 2>&1 | grep -q '$IFACE'"
    fi
    chk "eve.json exists and was written in the last 5 minutes" "Suricata is not writing logs: check container state and $LOGS permissions" \
        "[ -n \"\$(find $LOGS/eve.json -mmin -5 2>/dev/null)\" ]"
    chk "Both lab signatures have fired in eve.json (sid 9000001 and 9000002)" \
        "sudo tcpreplay --intf1=$IFACE $LAB/pcaps/lab-traffic.pcap   If only ICMP fires, see 6.1 note 2 (checksums)" \
        "grep -q '\"signature_id\":9000001' $LOGS/eve.json && grep -q '\"signature_id\":9000002' $LOGS/eve.json"
    chkw "eve.json is owned by $LAB_USER (PUID/PGID in effect)" "Check PUID/PGID in docker-compose.yml" "[ \"\$(stat -c %U $LOGS/eve.json)\" = $LAB_USER ]"
    if running fluent-bit; then
        chk "Fluent Bit: no HEC delivery errors in the last 2 minutes" "docker logs --since 5m fluent-bit   (403 = bad token, 400 = index missing or not allowed)" \
            "! T docker logs --since 2m fluent-bit 2>&1 | grep -qE 'http_status=4[0-9]{2}|\\[error\\]'"
        chk "Fluent Bit: no 'invalid indentation level' config error" "Normalise fluent-bit.conf (7.3 note 6) and restart fluent-bit" \
            "! T docker logs --tail 200 fluent-bit 2>&1 | grep -q 'invalid indentation'"
    fi
else
    todo "Docker daemon not reachable — runtime checks skipped" "sudo systemctl start docker, then cd $LAB && docker compose up -d"
fi

sec "10. Splunk configuration"
if $SPLUNK_UP; then
    chk "First boot finished ('Ansible playbook complete' in docker logs splunk)" "Wait 3-5 minutes after start: docker logs -f splunk" \
        "T docker logs splunk 2>&1 | grep -q 'Ansible playbook complete'"
    chk "Splunk Web reachable at http://localhost:8000" "Wait for first boot; check port 8000 mapping" "T curl -sL http://localhost:8000 | grep -q Splunk"
    chk "HEC healthy over plain HTTP (code 17)" "Needs SPLUNK_HEC_SSL=false in docker-compose.yml; Splunk must have finished booting" \
        "T curl -s http://localhost:8088/services/collector/health | grep -q '\"code\":17'"
else
    todo "Splunk container is not running — live Splunk checks skipped" "cd $LAB && docker compose up -d splunk"
fi

SPW=$(grep -oE 'SPLUNK_PASSWORD=[^[:space:]"'"'"']+' "$COMPOSE" 2>/dev/null | head -1 | cut -d= -f2-)
api() { T docker exec splunk curl -sk -u "admin:$SPW" "https://localhost:8089$1" "${@:2}" 2>/dev/null; }
FIX_IDX="docker exec -u splunk splunk /opt/splunk/bin/splunk add index suricata -auth 'admin:<password>'  (10.1)"
FIX_TOK="Run the 'Allow suricata on the token' curl in 10.1 (-d index=suricata -d indexes=suricata,main)"
REST_OK=false
if $SPLUNK_UP && [ -n "$SPW" ] && has jq && api "/services/server/info?output_mode=json" | jq -e .entry >/dev/null 2>&1; then REST_OK=true; fi

if $REST_OK; then
    ok "Admin login works with the password in docker-compose.yml"
    chk "Index 'suricata' exists" "$FIX_IDX" "api '/services/data/indexes/suricata?output_mode=json' | jq -e '.entry[0].name==\"suricata\"'"
    TOK=$(api "/servicesNS/nobody/splunk_httpinput/data/inputs/http?output_mode=json&count=0" \
        | jq -c --arg t "$HEC_TOKEN" '[.entry[]|select(.content.token==$t)|.content|{disabled,index,indexes}][0]' 2>/dev/null)
    chk "HEC token $HEC_TOKEN exists and is enabled" "Settings > Data Inputs > HTTP Event Collector: enable the token (10.1)" \
        "echo '$TOK' | jq -e '. != null and (.disabled|tostring) != \"true\" and (.disabled|tostring) != \"1\"'"
    chk "HEC token default index is suricata" "$FIX_TOK" "echo '$TOK' | jq -e '.index==\"suricata\"'"
    chk "HEC token allows index suricata" "$FIX_TOK" \
        "echo '$TOK' | jq -e '(.indexes|if type==\"array\" then . else (tostring|split(\",\")) end)|index(\"suricata\")!=null'"
    CSV=$(TMO=60 api /services/search/jobs/export -d output_mode=csv -d earliest_time=-7d \
        --data-urlencode 'search=search index=suricata NOT sourcetype="surilab:healthcheck" | stats count AS total, count(eval(event_type="alert")) AS alerts, count(eval('"'"'alert.signature'"'"'="ICMP Ping Detected")) AS icmp' | tail -1 | tr -d '"\r')
    TOTAL=$(echo "$CSV" | cut -d, -f1); ALERTS=$(echo "$CSV" | cut -d, -f2); ICMP=$(echo "$CSV" | cut -d, -f3)
    chk "Splunk has Suricata events in index=suricata, last 7 days (found: ${TOTAL:-0})" \
        "Check the pipeline in order: eve.json recent > fluent-bit logs > index and token settings (10.1)" "[ \"${TOTAL:-0}\" -gt 0 ] 2>/dev/null"
    chk "Splunk has alert events, last 7 days (found: ${ALERTS:-0})" \
        "Generate traffic: sudo tcpreplay --intf1=$IFACE $LAB/pcaps/lab-traffic.pcap, or ping the $IFACE gateway (10.2)" "[ \"${ALERTS:-0}\" -gt 0 ] 2>/dev/null"
    chk "ICMP Ping Detected alert has reached Splunk (found: ${ICMP:-0})" "ping -c 3 <$IFACE gateway>  (10.2)" "[ \"${ICMP:-0}\" -gt 0 ] 2>/dev/null"

    CIMN=$(TMO=60 api /services/search/jobs/export -d output_mode=csv -d earliest_time=-24h \
        --data-urlencode 'search=search index=suricata sourcetype=suricata tag=ids tag=attack | where isnotnull(signature) AND isnotnull(severity) AND isnotnull(src) | stats count' | tail -1 | tr -d '"\r')
    chk "CIM mapping works: tag=ids tag=attack events carry signature, severity, src (found: ${CIMN:-0}, last 24h)" \
        "Check the surilab_suricata_cim app and default.meta (10.4); restart Splunk; replay traffic" "[ \"${CIMN:-0}\" -gt 0 ] 2>/dev/null"

    sec "10.3 Splunk detection"
    DET='SuriLab - Suricata Rule Alert'
    DJ=$(api "/servicesNS/nobody/search/saved/searches/SuriLab%20-%20Suricata%20Rule%20Alert?output_mode=json" | jq -c '.entry[0].content|{search,is_scheduled,disabled,cron_schedule,"alert.track"}' 2>/dev/null | tr -d "'")
    chk "Alert '$DET' exists" "Create it with the curl block in 10.3 (expect HTTP 201)" "echo '$DJ' | jq -e '.search|test(\"9000001\")'"
    chk "Alert is scheduled and enabled" "Edit the alert in Splunk Web (Settings > Searches, reports, and alerts) or recreate it (10.3)" \
        "echo '$DJ' | jq -e '(.is_scheduled|tostring|test(\"^(1|true)\$\")) and (.disabled|tostring|test(\"^(0|false)\$\"))'"
    chk "Alert runs every minute and is tracked in Triggered Alerts" "Recreate with cron_schedule='* * * * *' and alert.track=1 (10.3)" \
        "echo '$DJ' | jq -e '.cron_schedule==\"* * * * *\" and (.[\"alert.track\"]|tostring|test(\"^(1|true)\$\"))'"
    chk "Alert has triggered at least once (Activity > Triggered Alerts)" "Ping the $IFACE gateway or replay the PCAP, wait 2 minutes, re-run (10.3)" \
        "api '/services/alerts/fired_alerts?output_mode=json&count=0' | jq -e --arg n \"\$DET\" '[.entry[]|select(.name==\$n)]|length>0'"
    LIC=$(api "/services/licenser/groups?output_mode=json" | jq -r '[.entry[]|select(.content.is_active|tostring|test("^(1|true)$"))|.name]|join(",")' 2>/dev/null)
    chk "Active license group allows alerting (found: ${LIC:-unknown})" \
        "On the Free license alerts never trigger. Wipe the Splunk volumes and redo 10.1 and 10.3 to get a fresh 60-day trial (10.3 note 1)" \
        "[ -n \"$LIC\" ] && ! echo \"$LIC\" | grep -qi free"
    manual "Settings > Licensing shows enough trial days left to cover the workshop (10.3 note 1)"
else
    $SPLUNK_UP && warn "Could not query the Splunk API (needs jq and the admin password from docker-compose.yml) — using the files on disk instead" \
        "Changing SPLUNK_PASSWORD in the compose file after first boot has no effect (10.1 note 4)"
    chk "Index 'suricata' defined on disk" "$FIX_IDX" \
        "grep -rqsE '^\\[suricata\\]' $LAB/splunk/etc/apps/*/local/indexes.conf $LAB/splunk/etc/system/local/indexes.conf"
    chk "HEC token default index is suricata, and suricata is allowed (inputs.conf)" "$FIX_TOK" \
        "grep -rqsE '^index[[:space:]]*=[[:space:]]*suricata' $LAB/splunk/etc/apps/splunk_httpinput/local/inputs.conf && grep -rqsE '^indexes[[:space:]]*=.*suricata' $LAB/splunk/etc/apps/splunk_httpinput/local/inputs.conf"
    chk "Alert 'SuriLab - Suricata Rule Alert' defined on disk" "Create it with the curl block in 10.3" \
        "grep -qsF '[SuriLab - Suricata Rule Alert]' $LAB/splunk/etc/apps/search/local/savedsearches.conf"
    manual "Splunk alert has triggered (Activity > Triggered Alerts) and the license is still Enterprise Trial (10.3)"
    manual "Splunk shows events and alerts in index=suricata (search: index=suricata event_type=alert | stats count by alert.signature)"
fi

if $ACTIVE && $SPLUNK_UP; then
    chk "HEC accepts a test event for index=suricata (\"code\":0)" "Create the index and allow it on the token (10.1)" \
        "T curl -s http://localhost:8088/services/collector/event -H 'Authorization: Splunk $HEC_TOKEN' -d '{\"event\":\"surilab build check\",\"index\":\"suricata\",\"sourcetype\":\"surilab:healthcheck\"}' | grep -q '\"code\":0'"
    GW=$(ip -4 -br addr show $IFACE 2>/dev/null | awk '{print $3}' | sed -E 's#\.[0-9]+/.*#.1#')
    if [ -n "$GW" ]; then
        BEFORE=$(grep -c '"signature_id":9000001' "$LOGS/eve.json" 2>/dev/null); BEFORE=${BEFORE:-0}
        ping -c 3 -W 2 "$GW" >/dev/null 2>&1; sleep 3
        AFTER=$(grep -c '"signature_id":9000001' "$LOGS/eve.json" 2>/dev/null); AFTER=${AFTER:-0}
        chk "Ping to $GW fires the ICMP rule in eve.json (sid 9000001)" "Check capture interface, HOME_NET and local.rules (10.2)" "[ $AFTER -gt $BEFORE ]"
    else warn "$IFACE has no IPv4 address — ping alert test skipped" "ip -br addr show $IFACE"; fi
else
    manual "HEC test event to index=suricata returns \"code\":0 — re-run with --active, or run validate-health.sh"
    manual "Ping to the $IFACE gateway produces an ICMP Ping Detected alert — re-run with --active (10.2)"
fi
manual "HEC test event still returns \"code\":0 after: docker compose restart splunk (10.1 note 3)"

# =================================================================================
sec "13. Fault injection testing (evidence in /var/log/surilab/inject-fault.log)"
ILOG=$(cat /var/log/surilab/inject-fault.log /var/log/surilab/inject-fault.log.1 2>/dev/null; zcat /var/log/surilab/inject-fault.log.*.gz 2>/dev/null)
NOT_RUN=""
for n in 1 2 3 4 5; do echo "$ILOG" | grep -q "Scenario $n:" || NOT_RUN="$NOT_RUN $n"; done
if [ -z "$NOT_RUN" ]; then ok "inject-fault.sh has been run for all 5 scenarios"
else todo "inject-fault.sh not yet run for scenario(s):$NOT_RUN" "sudo $SCRIPTS/inject-fault.sh <n>, confirm the symptom, then sudo $SCRIPTS/heal-lab.sh"; fi
chk "inject-fault.sh --dry-run has been tested" "sudo $SCRIPTS/cron-fault-s2.sh --dry-run && sudo tail -5 /var/log/surilab/inject-fault.log" \
    "echo \"\$ILOG\" | grep -q 'DRY-RUN'"
chkw "heal-lab.sh has run under cron (heal-lab.log exists)" "Only expected with schedule Option A or C" "[ -s /var/log/surilab/heal-lab.log ]"
manual "Scenario 1 makes Suricata fail; scenario 5 shows http_status=403 in docker logs fluent-bit"
manual "heal-lab.sh restores a healthy state and validate-health.sh then reports 0 failures"
manual "inject-fault.sh --quiet prints nothing to the terminal"
manual "A temporary cron entry fires: grep CRON /var/log/syslog | tail"
manual "sudo tcpreplay --intf1=$IFACE $LAB/pcaps/lab-traffic.pcap replays without error and events reach Splunk"

# =================================================================================
sec "12. Pre-export (do these last)"
if ip link show ens33 >/dev/null 2>&1 && ip -br link show ens33 | grep -qw UP; then
    warn "NAT adapter ens33 is still connected" "Fine while building. Remove or disable it before export (12.1)"
else ok "NAT adapter removed or disabled"; fi
chkw "DNS set to 8.8.8.8" "Set in the connection's IPv4 settings before export (12.1)" \
    "resolvectl dns 2>/dev/null | grep -q '8\\.8\\.8\\.8' || grep -rqs '8\\.8\\.8\\.8' /etc/netplan /etc/NetworkManager/system-connections /etc/systemd/resolved.conf"
manual "Reboot test passed: all three containers start by themselves after a restart (12.2 note 1)"
manual "prepare-for-export.sh run; free space zeroed (12.3); VM shut down cleanly with the containers still running"
manual "OVA exported as SuriLab-2026-v11.ova, under 15 GB, imports on a second machine, validate-health.sh passes there"

# =================================================================================
TOTALN=$((DONE+TODO))
PCT=0; [ "$TOTALN" -gt 0 ] && PCT=$((DONE*100/TOTALN))
printf '\n%s================ SUMMARY ================%s\n' "$B" "$N"
printf '  %sDONE %d%s   %sTODO %d%s   %sWARN %d%s   %sMANUAL %d%s   —   %d%% of automatic checks complete\n' \
    "$G" "$DONE" "$N" "$R" "$TODO" "$N" "$Y" "$WARN" "$N" "$C" "$MANL" "$N" "$PCT"

if [ "$TODO" -gt 0 ]; then
    printf '\n%sSTILL TO DO (%d), in build order:%s\n' "$R" "$TODO" "$N"; i=0
    for e in "${TODO_LIST[@]}"; do i=$((i+1)); IFS='|' read -r s d f <<< "$e"
        printf '  %2d. [%s] %s\n' "$i" "$s" "$d"; [ -n "$f" ] && printf '      fix: %s\n' "$f"; done
else
    printf '\n%sNo automatic check is outstanding.%s\n' "$G" "$N"
fi
if [ "$WARN" -gt 0 ]; then
    printf '\n%sREVIEW (%d):%s\n' "$Y" "$WARN" "$N"
    for e in "${WARN_LIST[@]}"; do IFS='|' read -r s d f <<< "$e"; printf '   - [%s] %s\n' "$s" "$d"; done
fi
printf '\n%sCONFIRM BY HAND (%d):%s\n' "$C" "$MANL" "$N"
for e in "${MANL_LIST[@]}"; do IFS='|' read -r s d <<< "$e"; printf '   [ ] %s\n' "$d"; done

[ "$TODO" -eq 0 ]
}

main 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' > "$REPORT")
RC=${PIPESTATUS[0]}
sleep 0.3
printf '\nReport saved (plain text): %s\n' "$REPORT"
exit "$RC"
