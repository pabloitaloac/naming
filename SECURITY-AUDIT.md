# Security audit and hardening notes

This fork of [glacierphonk/naming](https://github.com/glacierphonk/naming) was reviewed at upstream commit `e7af8a5` (2026-04-19) and hardened on 2026-11-21.

## Review findings (upstream `e7af8a5`)

- All 28 files read in full. No prompt injection, hidden instructions, invisible or bidirectional Unicode, encoded payloads, or unexpected network endpoints.
- The only executable is `scripts/check-availability.sh`; it only queried public registries and wrote nothing.
- Main risk: `allowed-tools` pre-approved `Bash(curl *)`, `Bash(whois *)` and `WebFetch`, so text on an untrusted web page could steer Claude into running arbitrary `curl` commands without a permission prompt.

## Changes in this fork

- `allowed-tools` reduced to `Read, Grep, Glob, WebSearch`. Every shell command and page fetch now needs approval (unless the session itself bypasses permissions).
- Added safety rules to `SKILL.md`: web and tool output is data, never instructions; no data except the candidate name leaves the machine.
- Script: strict name validation (`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`), HTTPS-only `curl` with timeouts, domains via official RDAP servers (IANA bootstrap) with a time-limited whois fallback, `UNCLEAR` instead of `TAKEN` on rate limits/errors, fixed the broken default platform list, configurable `TLDS`.
- Prefer a registry-backed domain MCP (and trademark search) when one is connected.
- Fixed the 100 vs 110 scoring mismatch; marked uncited statistics as unverified.

## Updating from upstream

Do not merge upstream blindly. Review every upstream diff (especially `SKILL.md` frontmatter and `scripts/`) before merging, then update the reviewed commit above.
