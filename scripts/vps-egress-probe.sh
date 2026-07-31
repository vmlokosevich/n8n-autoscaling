#!/usr/bin/env bash
# vps-egress-probe.sh — check whether a VPS has usable egress for n8n-style workloads
# (DNS, Cloudflare, Telegram API, Google APIs).
#
# Usage:
#   bash scripts/vps-egress-probe.sh
#   CF_HOST=example.com bash scripts/vps-egress-probe.sh
#   CF_TEST_IPS="1.2.3.4 5.6.7.8" bash scripts/vps-egress-probe.sh
#
# Optional env:
#   CF_HOST       Hostname behind Cloudflare to resolve and probe per A record
#                 (default: cloudflare.com)
#   CF_TEST_IPS   Extra IPv4s to TCP/443 probe (space-separated; default: empty)
#   TG_HOST       Telegram API host (default: api.telegram.org)
#   GOOGLE_HOSTS  Space-separated Google hosts to HTTPS-probe
#   TIMEOUT       Connect timeout seconds (default: 8)

set -u

CF_HOST="${CF_HOST:-cloudflare.com}"
CF_TEST_IPS="${CF_TEST_IPS:-}"
TG_HOST="${TG_HOST:-api.telegram.org}"
GOOGLE_HOSTS="${GOOGLE_HOSTS:-www.googleapis.com oauth2.googleapis.com www.google.com}"
TIMEOUT="${TIMEOUT:-8}"
PASS=0
FAIL=0
WARN=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr() { printf '\n==== %s ====\n' "$*"; }

ok() { green "PASS: $*"; PASS=$((PASS + 1)); }
bad() { red "FAIL: $*"; FAIL=$((FAIL + 1)); }
warn() { yellow "WARN: $*"; WARN=$((WARN + 1)); }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    bad "need command: $1"
    return 1
  }
}

tcp_check() {
  local ip="$1" port="$2" label="$3"
  if command -v nc >/dev/null 2>&1; then
    if nc -vz -w "$TIMEOUT" "$ip" "$port" >/dev/null 2>&1; then
      ok "TCP $label $ip:$port"
      return 0
    fi
    bad "TCP $label $ip:$port (timeout/refused)"
    return 1
  fi
  if timeout "$TIMEOUT" bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
    ok "TCP $label $ip:$port"
    return 0
  fi
  bad "TCP $label $ip:$port"
  return 1
}

https_check() {
  local url="$1" label="$2"
  shift 2
  local extra=("$@")
  local out
  out=$(curl -4 -o /dev/null -sS -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_total}' \
    --connect-timeout "$TIMEOUT" --max-time $((TIMEOUT * 2)) \
    "${extra[@]}" "$url" 2>/dev/null) || {
    bad "HTTPS $label ($url) — curl failed/timeout"
    return 1
  }
  # shellcheck disable=SC2086
  set -- $out
  local code="$1" dns="$2" conn="$3" tls="$4" total="$5"
  if [[ "$code" == "000" ]]; then
    bad "HTTPS $label code=000 dns=${dns}s connect=${conn}s total=${total}s"
    return 1
  fi
  if awk -v c="$conn" 'BEGIN { exit !(c + 0 > 2.0) }'; then
    warn "HTTPS $label slow connect=${conn}s (code=$code total=${total}s)"
    return 0
  fi
  ok "HTTPS $label code=$code dns=${dns}s connect=${conn}s tls=${tls}s total=${total}s"
}

dns_udp() {
  local host="$1" resolver="$2"
  if dig +time=2 +tries=1 @"$resolver" "$host" A +short 2>/dev/null | grep -Eq '^[0-9]+\.'; then
    ok "DNS UDP @$resolver $host"
  else
    bad "DNS UDP @$resolver $host"
  fi
}

dns_tcp() {
  local host="$1" resolver="$2"
  if dig +tcp +time=2 +tries=1 @"$resolver" "$host" A +short 2>/dev/null | grep -Eq '^[0-9]+\.'; then
    ok "DNS TCP @$resolver $host"
  else
    bad "DNS TCP @$resolver $host"
  fi
}

dns_tls() {
  local host="$1" resolver="$2"
  if dig +tls +time=3 +tries=1 @"$resolver" "$host" A +short 2>/dev/null | grep -Eq '^[0-9]+\.'; then
    ok "DNS DoT @$resolver:853 $host"
  else
    warn "DNS DoT @$resolver:853 $host (optional; dig may lack +tls)"
  fi
}

echo "VPS egress probe — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname 2>/dev/null || echo unknown)"
echo "CF_HOST=$CF_HOST  TIMEOUT=${TIMEOUT}s"
ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true

need curl || exit 1
command -v dig >/dev/null 2>&1 || warn "dig not installed (apt-get install -y dnsutils) — DNS tests limited"
command -v nc >/dev/null 2>&1 || warn "nc not installed — using bash /dev/tcp fallback"

# ---------- DNS ----------
hdr "DNS (UDP / TCP / DoT)"
if command -v dig >/dev/null 2>&1; then
  for r in 1.1.1.1 8.8.8.8; do
    dns_udp cloudflare.com "$r"
    dns_tcp cloudflare.com "$r"
  done
  dns_tls cloudflare.com 1.1.1.1
  dns_tls cloudflare.com 8.8.8.8
else
  if getent ahostsv4 cloudflare.com >/dev/null 2>&1; then
    ok "getent cloudflare.com"
  else
    bad "getent cloudflare.com"
  fi
fi

# ---------- Cloudflare ----------
hdr "Cloudflare"
https_check "https://1.1.1.1/" "1.1.1.1"
https_check "https://cloudflare.com/" "cloudflare.com"

CF_IPS=()
if command -v dig >/dev/null 2>&1; then
  mapfile -t CF_IPS < <(dig +short "$CF_HOST" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
fi
if [[ ${#CF_IPS[@]} -eq 0 ]]; then
  mapfile -t CF_IPS < <(getent ahostsv4 "$CF_HOST" 2>/dev/null | awk '{print $1}' | sort -u || true)
fi

if [[ ${#CF_IPS[@]} -eq 0 ]]; then
  bad "cannot resolve $CF_HOST"
else
  echo "A records for $CF_HOST: ${CF_IPS[*]}"
  for ip in "${CF_IPS[@]}"; do
    tcp_check "$ip" 443 "CF/$CF_HOST"
    https_check "https://${CF_HOST}/" "CF $CF_HOST via $ip" --resolve "${CF_HOST}:443:${ip}"
  done
fi

if [[ -n "$CF_TEST_IPS" ]]; then
  for ip in $CF_TEST_IPS; do
    tcp_check "$ip" 443 "CF-test-ip"
  done
fi

# ---------- Telegram ----------
hdr "Telegram (ICMP can lie — TCP/443 matters)"
TG_IP=""
if command -v dig >/dev/null 2>&1; then
  TG_IP=$(dig +short "$TG_HOST" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
fi
[[ -z "$TG_IP" ]] && TG_IP=$(getent ahostsv4 "$TG_HOST" 2>/dev/null | awk '{print $1; exit}' || true)

if [[ -n "$TG_IP" ]]; then
  echo "TG A: $TG_IP"
  if ping -c 2 -W 2 "$TG_IP" >/dev/null 2>&1; then
    ok "ICMP ping $TG_IP (informational only)"
  else
    warn "ICMP ping $TG_IP failed (often OK if TCP works)"
  fi
  tcp_check "$TG_IP" 443 "Telegram"
  https_check "https://${TG_HOST}/" "Telegram API" --resolve "${TG_HOST}:443:${TG_IP}"
else
  bad "cannot resolve $TG_HOST"
fi

# ---------- Google ----------
hdr "Google / Google APIs"
for h in $GOOGLE_HOSTS; do
  https_check "https://${h}/" "$h"
done
tcp_check 8.8.8.8 53 "GoogleDNS-TCP53" || true
tcp_check 8.8.8.8 443 "GoogleDNS-443" || true

# ---------- Summary ----------
hdr "Summary"
echo "PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo
if [[ "$FAIL" -eq 0 ]]; then
  green "VERDICT: suitable (no hard failures). Watch WARNs for slow connect."
  exit 0
fi
red "VERDICT: not suitable until FAIL items are fixed by provider/network."
echo "Typical blockers for n8n:"
echo "  - DNS UDP/TCP timeouts  -> getaddrinfo EAI_AGAIN"
echo "  - one CF anycast FAIL, other PASS -> intermittent long HTTP connects"
echo "  - Telegram TCP/443 FAIL (even if ping OK) -> Telegram nodes broken"
echo "  - Google API HTTPS FAIL -> Google nodes broken"
exit 1
