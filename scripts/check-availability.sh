#!/usr/bin/env bash
# check-availability.sh — Quick availability check for a product name
# Usage: bash check-availability.sh <name> [platforms...]
# Platforms: domain, npm, pypi, github, ghrepo:<org>, crates, rubygems, wp, telegram
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
# Nothing from a network response is ever printed: output is limited to fixed strings
# and HTTP status codes, so registry or web content cannot inject text into the session.

set -euo pipefail

usage() { echo "Usage: check-availability.sh <name> [domain|npm|pypi|github|ghrepo:<org>|crates|rubygems|wp|telegram ...]" >&2; exit 2; }

# Print an untrusted value safely (no escape sequences reach the terminal).
safe() { printf '%q' "$1"; }

NAME_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

[ $# -ge 1 ] || usage
NAME=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
shift

# Allow only DNS-label-style names: a-z, 0-9 and inner hyphens, 1-63 chars.
# This blocks path, query, option and shell tricks in URLs and command arguments.
if ! [[ "$NAME" =~ $NAME_RE ]]; then
  echo "Invalid name: $(safe "$NAME") (use lowercase letters, digits and inner hyphens only, max 63 chars)" >&2
  exit 2
fi

if [ $# -eq 0 ]; then
  PLATFORMS=(domain github npm)
else
  PLATFORMS=("$@")
fi
TLD_LIST=()
read -r -a TLD_LIST <<< "${TLDS:-com dev io}" || true
[ ${#TLD_LIST[@]} -gt 0 ] || TLD_LIST=(com dev io)

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi
UA='naming-skill-availability-check/1.0'

ok()   { printf '  %bAVAILABLE%b  %s\n' "$GREEN" "$NC" "$1"; }
taken(){ printf '  %bTAKEN%b      %s\n' "$RED" "$NC" "$1"; }
warn() { printf '  %bUNCLEAR%b    %s\n' "$YELLOW" "$NC" "$1"; }

# curl: ignore ~/.curlrc (-q), no URL globbing (-g), HTTPS only (also on redirects),
# bounded connect and total time.
CURL=(curl -q -g -s --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 10 -A "$UA")

http_code() {
  "${CURL[@]}" -o /dev/null -L -w '%{http_code}' "$1" 2>/dev/null || echo "000"
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

# Prefer system binaries over whatever is first on PATH.
pick_bin() {
  local b
  for b in "$@"; do
    if [ -x "$b" ]; then echo "$b"; return; fi
  done
  command -v "$(basename "$1")" 2>/dev/null || true
}
PYTHON=$(pick_bin /usr/bin/python3)
PERL=$(pick_bin /usr/bin/perl)
WHOIS=$(pick_bin /usr/bin/whois)

# RDAP server for a TLD: IANA's official bootstrap list, plus registries IANA does not list yet.
RDAP_BOOTSTRAP=""
rdap_base() {
  local tld="$1"
  case "$tld" in
    io) echo "https://rdap.identitydigital.services/rdap/"; return ;;
  esac
  [ -n "$RDAP_BOOTSTRAP" ] || return 0
  [ -n "$PYTHON" ] || return 0
  printf '%s' "$RDAP_BOOTSTRAP" | "$PYTHON" -I -c '
import json, sys
tld = sys.argv[1]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for tlds, urls in data.get("services", []):
    if tld in tlds:
        https = [u for u in urls if isinstance(u, str) and u.startswith("https://")]
        if https:
            print(https[0] if https[0].endswith("/") else https[0] + "/")
        break
' "$tld" 2>/dev/null || true
}

# whois fallback for TLDs without RDAP, with a hard time limit.
# AVAILABLE only on an explicit "does not exist" answer; TAKEN only on real registration
# fields; anything else (both, neither, refused) is UNCLEAR.
whois_check() {
  local domain="$1" out avail=0 reg=0
  if [ -z "$WHOIS" ] || [ -z "$PERL" ]; then
    warn "$domain (no RDAP server and whois/perl not available — check at a registrar)"
    return
  fi
  out=$(env -u PERL5OPT -u PERL5LIB "$PERL" -e 'alarm shift; exec @ARGV' 12 "$WHOIS" -- "$domain" 2>&1 || true)
  if printf '%s' "$out" | grep -qiE "domain not found|no match for|no data found|no entries found|no object found|object does not exist|status: *free|status: *available|^not found"; then
    avail=1
  fi
  if printf '%s' "$out" | grep -qiE "^[[:space:]]*(creation date|created on|registered on|registration date|registry expiry date|expiry date|registrar):[[:space:]]*[^[:space:]]|^[[:space:]]*status:[[:space:]]*connect"; then
    reg=1
  fi
  if [ "$avail" = 1 ] && [ "$reg" = 0 ]; then
    ok "$domain (whois)"
  elif [ "$reg" = 1 ] && [ "$avail" = 0 ]; then
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
        RDAP_BOOTSTRAP=$("${CURL[@]}" https://data.iana.org/rdap/dns.json 2>/dev/null || true)
      fi
      for tld in "${TLD_LIST[@]}"; do
        if ! [[ "$tld" =~ ^[a-z]{2,24}$ ]]; then
          warn "invalid TLD $(safe "$tld") — skipped"
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
    ghrepo:*)
      org=$(printf '%s' "${platform#ghrepo:}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
      if ! [[ "$org" =~ $NAME_RE ]]; then
        warn "invalid GitHub org $(safe "$org") — skipped"
        continue
      fi
      report_http "GitHub repo: ${org}/${NAME} (AVAILABLE = no public repo; only meaningful if you own the org)" "$(http_code "https://github.com/${org}/${NAME}")"
      ;;
    crates)
      report_http "crates.io: ${NAME}" "$(http_code "https://crates.io/api/v1/crates/${NAME}")"
      ;;
    rubygems)
      report_http "RubyGems: ${NAME}" "$(http_code "https://rubygems.org/api/v1/gems/${NAME}.json")"
      ;;
    wp)
      body=$("${CURL[@]}" "https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&slug=${NAME}" 2>/dev/null || true)
      if printf '%s' "$body" | grep -qi "plugin not found"; then
        ok "WP plugin: ${NAME}"
      elif printf '%s' "$body" | grep -q "\"slug\""; then
        taken "WP plugin: ${NAME}"
      else
        warn "WP plugin: ${NAME} (no clear answer — re-check)"
      fi
      ;;
    telegram)
      body=$("${CURL[@]}" -L "https://t.me/${NAME}" 2>/dev/null || true)
      if printf '%s' "$body" | grep -q "tgme_page_title"; then
        taken "Telegram: @${NAME}"
      else
        warn "Telegram: @${NAME} (no public profile found — may be available, verify in app)"
      fi
      ;;
    *)
      echo "  Unknown platform: $(safe "$platform") (valid: domain, npm, pypi, github, ghrepo:<org>, crates, rubygems, wp, telegram)"
      ;;
  esac
done

echo "---"
echo "Note: automated checks can be wrong. Confirm at a registrar before buying, and run a trademark search."
