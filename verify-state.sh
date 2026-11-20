#!/usr/bin/env bash
# Read-only state check for the hardening work. Prints no secrets.
# Reads its values from env.local (same directory). Run in a normal terminal;
# sudo will ask for your password.
# Usage: bash verify-state.sh > state.txt 2>&1
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$DIR/env.local" ]; then
  echo "env.local not found in $DIR. Copy env.template to env.local and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$DIR/env.local"

section() { printf '\n== %s ==\n' "$1"; }

section "Listening TCP sockets"
sudo ss -tlnp | awk 'NR==1 || /LISTEN/'

section "Processes and their users"
ps -eo user:20,args | grep -E "${PROM_USER}|node_exporter|nut-exporter|grafana|ghost|cloudflared" | grep -v grep | cut -c1-120

section "Service states"
for u in ssh ufw fail2ban nginx cloudflared "$PROM_USER" node_exporter nut_exporter grafana-server "$GHOST_UNIT" tailscaled; do
  printf '%-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
done

section "UFW"
sudo ufw status verbose

section "SSH effective settings (selected)"
sudo sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|allowusers|x11forwarding|maxauthtries|logingracetime) '

section "fail2ban sshd jail"
sudo fail2ban-client status sshd 2>&1 | head -12

section "nginx enabled sites"
ls -1 /etc/nginx/sites-enabled/

section "Ghost config (no secret values printed)"
CFG="$GHOST_DIR/config.production.json"
stat -c '%U:%G %a %n' "$CFG"
python3 -c "
import json
d = json.load(open('$CFG'))
print('staffDeviceVerification =', d.get('security', {}).get('staffDeviceVerification'))
print('db password present in file =', 'password' in d.get('database', {}).get('connection', {}))
"

section "Ghost version"
(cd "$GHOST_DIR" && ghost version 2>&1 | head -4)

section "Prometheus targets"
curl -s -m 5 "http://127.0.0.1:${PROM_PORT}/api/v1/targets" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print([(t['labels']['job'], t['health']) for t in d['data']['activeTargets']])
except Exception as e:
    print('could not read targets:', e)
"

section "HTTP checks"
curl -s -m 5 -o /dev/null -w 'ghost local       %{http_code}\n' "http://127.0.0.1:${GHOST_PORT}/"
curl -s -m 5 -o /dev/null -w 'public site       %{http_code}\n' "https://${PUBLIC_DOMAIN}/"
curl -s -m 5 -o /dev/null -w 'ghost admin (access) %{http_code} %{redirect_url}\n' "https://${PUBLIC_DOMAIN}/ghost/"
curl -s -m 5 -o /dev/null -w 'ghost api (access)   %{http_code} %{redirect_url}\n' "https://${PUBLIC_DOMAIN}/ghost/api/admin/site/"

section "Done"
echo "verify-state complete"
