#!/bin/bash
#
# hook.sh — prometheus bootstrap, stage 1 (PUBLIC).
#
# Run on a bare Proxmox host console:
#   curl -fsSL https://raw.githubusercontent.com/thanadiosa/prometheus/main/hook.sh | bash
#
# Stage 1 is tiny and stable: establish SSH access to the helper (SFTP) server,
# fetch the needle (stage 2), run it. All address-specific logic lives in the
# needle. No secret or private address is baked into this file — it is public.
#
set -uo pipefail
reset

NEEDLE_REMOTE="downloads/helper/starter/scripts/start.sh"   # path on the helper
HELPER_CACHE="/root/helper"                                 # caches user@host

log() { printf '\n[hook] %s\n' "$*" >&2; }

# ── Resolve helper (user@host), cached across runs ────────────────────────────
# Loop so a wrong/unreachable entry re-prompts instead of forcing a one-liner
# restart. A cached value is used once; if it fails it is cleared and re-asked.
while :; do
  if [[ -f $HELPER_CACHE ]]; then
    helper=$(cat "$HELPER_CACHE")
    log "using cached helper ($helper)"
  else
    read -r -p "helper (user@host): " helper
  fi

  if [[ -z $helper || $helper != *@* ]]; then
    log "expected user@host, try again"
    rm -f "$HELPER_CACHE"
    continue
  fi
  helper_server="${helper#*@}"

  # Reachability pre-check → fast, clear failure.
  if ! nc -z -w 5 "$helper_server" 22 2>/dev/null; then
    log "helper unreachable on :22 — re-enter"
    rm -f "$HELPER_CACHE"
    continue
  fi

  # Trust host key (TOFU) and push our key so scp is non-interactive.
  mkdir -p ~/.ssh
  ssh-keyscan "$helper_server" >> ~/.ssh/known_hosts 2>/dev/null
  ssh-copy-id "$helper" 1>/dev/null 2>&1

  # Fetch the needle. Success validates access; failure re-prompts.
  if scp "$helper:$NEEDLE_REMOTE" ./needle.sh 2>/dev/null; then
    echo "$helper" > "$HELPER_CACHE"   # persist only after a working fetch
    break
  fi
  log "could not fetch the needle — check access; re-enter"
  rm -f "$HELPER_CACHE"
done

# ── Hand off ──────────────────────────────────────────────────────────────────
chmod +x ./needle.sh
log "running the needle"
./needle.sh "$helper"
