#!/usr/bin/env bash
# check-availability.sh — Quick availability check for a product name
# Usage: bash check-availability.sh <name> [platforms...]
# Platforms: domain, npm, pypi, github, crates, rubygems, wp, telegram
# If no platforms are given, checks: domain github npm
# Domain TLDs default to "com dev io"; override with TLDS="com app co".
#
# Results:
#   AVAILABLE — the registry said the name does not exist
#   TAKEN     — the registry returned a record for the name
#   UNCLEAR   — anything else (rate limit, timeout, unknown response). Re-check; never
#               treat UNCLEAR as available or taken.
#
# Only the candidate name is sent out, and only to the public registries below.

set -euo pipefail

usage() { echo "Usage: check-availability.sh <name> [domain|npm|pypi|github|crates|rubygems|wp|telegram ...]" >&2; exit 2; }

[ $# -ge 1 ] || usage
NAME=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
shift

# Allow only DNS-label-style names: a-z, 0-9 and inner hyphens, 1-63 chars.
# This blocks path, query, option and shell tricks in URLs and command arguments.
if ! [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Invalid name: '$NAME' (use lowercase letters, digits and inner hyphens only, max 63 chars)" >&2
  exit 2
fi

if [ $# -eq 0 ]; then
  PLATFORMS=(domain github npm)
else
  PLATFORMS=("$@")
fi
read -r -a TLD_LIST <<< "${TLDS:-com dev io}"

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi
UA='naming-skill-availability-check/1.0'
ok()   { echo -e "  ${GREEN}AVAILABLE${NC}  $1"; }
taken(){ echo -e "  ${RED}TAKEN${NC}      $1"; }
warn() { echo -e "  ${YELLOW}UNCLEAR${NC}    $1"; }

# HTTPS only, no redirects to other protocols, bounded time.
http_code() {
  curl -s -o /dev/null --proto '=https' --proto-redir '=https' --max-time 15 -L -A "$UA" \
       -w '%{http_code}' "$1" 2>/dev/null || echo "000"
}

# Map an HTTP status to a result: 404 = available, 200 = taken, else unclear.
report_http() {
  local label="$1" code="$2"
  case "$code" in
    404) ok "$label" ;;
    200) taken "$label" ;;
    *)   warn "$label (HTTP $code — re-check)" ;;
  esac
}

# RDAP server for a TLD: IANA's official bootstrap list, plus registries IANA does not list yet.
RDAP_BOOTSTRAP=""
rdap_base() {
  local tld="$1"
  case "$tld" in
    io) echo "https://rdap.identitydigital.services/rdap/"; return ;;
  esac
  [ -n "$RDAP_BOOTSTRAP" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  printf '%s' "$RDAP_BOOTSTRAP" | python3 -I -c '
import json, sys
tld = sys.argv[1]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for tlds, urls in data.get("services", []):
    if tld in tlds:
        https = [u for u in urls if u.startswith("https://")]
        if https:
            print(https[0] if https[0].endswith("/") else https[0] + "/")
        break
' "$tld" 2>/dev/null || true
}

# whois fallback for TLDs without RDAP, with a hard time limit.
whois_check() {
  local domain="$1" out
  if ! command -v whois >/dev/null 2>&1; then
    warn "$domain (no RDAP server and whois not installed — check at a registrar)"
    return
  fi
  out=$(perl -e 'alarm shift; exec @ARGV' 20 whois -- "$domain" 2>&1 || true)
  if printf '%s' "$out" | grep -qiE "domain not found|no match for|not found\.|no data found|no entries found|status: *free|status: *available"; then
    ok "$domain (whois)"
  elif printf '%s' "$out" | grep -qiE "^[[:space:]]*domain name:[[:space:]]*[a-z0-9]|^[[:space:]]*creation date:"; then
    taken "$domain (whois)"
  else
    warn "$domain (whois gave no clear answer — check at a registrar)"
  fi
}

echo "Checking availability for: ${NAME}"
echo "---"

for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    domain)
      if [ -z "$RDAP_BOOTSTRAP" ]; then
        RDAP_BOOTSTRAP=$(curl -s --proto '=https' --max-time 15 https://data.iana.org/rdap/dns.json 2>/dev/null || true)
      fi
      for tld in "${TLD_LIST[@]}"; do
        if ! [[ "$tld" =~ ^[a-z]{2,24}$ ]]; then
          warn "invalid TLD '$tld' — skipped"
          continue
        fi
        base=$(rdap_base "$tld")
        if [ -n "$base" ]; then
          report_http "${NAME}.${tld} (RDAP)" "$(http_code "${base}domain/${NAME}.${tld}")"
        else
          whois_check "${NAME}.${tld}"
        fi
      done
      ;;
    npm)
      report_http "npm: ${NAME}" "$(http_code "https://registry.npmjs.org/${NAME}")"
      ;;
    pypi)
      report_http "PyPI: ${NAME}" "$(http_code "https://pypi.org/pypi/${NAME}/json")"
      ;;
    github)
      report_http "GitHub user/org: ${NAME}" "$(http_code "https://github.com/${NAME}")"
      ;;
    crates)
      report_http "crates.io: ${NAME}" "$(http_code "https://crates.io/api/v1/crates/${NAME}")"
      ;;
    rubygems)
      report_http "RubyGems: ${NAME}" "$(http_code "https://rubygems.org/api/v1/gems/${NAME}.json")"
      ;;
    wp)
      body=$(curl -s --proto '=https' --max-time 15 \
        "https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&slug=${NAME}" 2>/dev/null || true)
      if printf '%s' "$body" | grep -qi "plugin not found"; then
        ok "WP plugin: ${NAME}"
      elif printf '%s' "$body" | grep -q "\"slug\""; then
        taken "WP plugin: ${NAME}"
      else
        warn "WP plugin: ${NAME} (no clear answer — re-check)"
      fi
      ;;
    telegram)
      body=$(curl -sL --proto '=https' --max-time 15 "https://t.me/${NAME}" 2>/dev/null || true)
      if printf '%s' "$body" | grep -q "tgme_page_title"; then
        taken "Telegram: @${NAME}"
      else
        warn "Telegram: @${NAME} (no public profile found — may be available, verify in app)"
      fi
      ;;
    *)
      echo "  Unknown platform: $platform (valid: domain, npm, pypi, github, crates, rubygems, wp, telegram)"
      ;;
  esac
done

echo "---"
echo "Note: automated checks can be wrong. Confirm at a registrar before buying, and run a trademark search."
