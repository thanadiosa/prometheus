#!/usr/bin/env bash
# bin/dev-container-move.sh — copy one development container's data from the OPERATOR'S LAPTOP
# to the estate's development server, remove it again (#1140, part of #1131), or fetch it back.
#
#   bin/dev-container-move.sh copy   [--dry-run] [flags] <container>
#   bin/dev-container-move.sh remove [flags] <container>
#   bin/dev-container-move.sh fetch  [flags] <all|repos|memory|conversations|logins> <container> [<dest>]
#
# Runs on the laptop, never on the estate. It moves the four things #1138 gave each container
# its own folder for: the checkout (repos), memory, past conversations and logins.
#
# WHERE THE SERVER IS: --host / DEVSERVER_HOST (a name or address you already use), account
# --user / DEVSERVER_USER (default: your laptop login; it must be one of the estate's `users:`).
# Nothing about the server is kept in this repo. A plain name or address is written to a private
# temporary ssh config, so argv only ever carries the alias `devserver` (no address on a
# command line). If --host is a Host alias of your own ~/.ssh/config, it is used AS the alias
# (same HostName, user, keys and known-hosts name as your `ssh <host>`, #1166).
#
# WHERE THE LAPTOP DATA IS (from .devcontainer/devcontainer.json; each one has a flag + env):
#   --repo-dir          DEVCOPY_REPO_DIR           the checkout (default for `prometheus`: this repo)
#   --memory-dir        DEVCOPY_MEMORY_DIR         ~/.claude/projects/<repo-path-slug>/memory
#   --logins-dir        DEVCOPY_LOGINS_DIR         the container's ~/.claude (default: read out of
#                                                  the docker volume <container>-devc-claude)
#   --conversations-dir DEVCOPY_CONVERSATIONS_DIR  <logins-dir>/projects
#   --gh-dir            DEVCOPY_GH_DIR             optional: also send this ~/.config/gh as gh/
#   --volume            DEVCOPY_VOLUME             the docker volume to read the logins from
#   --image             DEVCOPY_IMAGE              image used to read that volume (default: the
#                                                  vsc-prometheus-* devcontainer image)
#
# HOW IT WRITES: two hops, because the estate's sudo asks for a password (no NOPASSWD), which
# rsync cannot answer. Hop 1 rsyncs as you into a private 0700 staging folder in your server
# home; hop 2 is ONE `ssh -t sudo` (you type the password once) that rsyncs staging into
# /srv/dev/<kind>/<n> as root with --chown devcontainer, sets the modes, deletes staging and
# stops and restarts that one container. Copy never uses --delete; only remove does.
#
# FETCH (#1589) is the other way, also started from the desktop (the server holds no key to it):
# ONE `ssh -t sudo` copies the four folders (the same cut as copy) into a private 0700 staging
# folder in your server home, rsync brings them into <dest>/<container>/<date>/ (default dest:
# DEVCOPY_FETCH_DIR or ~/dev-container-fetch; never inside this repo), staging is removed.
# A same-day fetch gets a time suffix, never overwrites. It prints the memory folder's checksums
# on both sides and a match line. A running container is paused while it is read, so the
# memory check compares one moment. A fetched set is copy's input: see the handbook.
# shellcheck disable=SC2034  # EXCL_* / SRC_* are read through indirect names
set -euo pipefail

REMOTE_ROOT=/srv/dev
# DEVCOPY_REMOTE_ROOT exists for the test suite only (it sets DEVCOPY_TEST=1); otherwise ignored.
if [ -n "${DEVCOPY_REMOTE_ROOT:-}" ]; then
  if [ "${DEVCOPY_TEST:-}" = 1 ]; then REMOTE_ROOT=$DEVCOPY_REMOTE_ROOT
  else printf 'dev-container-move: ignoring DEVCOPY_REMOTE_ROOT (test-only); using /srv/dev\n' >&2; fi
fi
REMOTE_OWNER=devcontainer
STAGE_REL=.provisioner-devcopy
REPO_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KINDS=(repos memory conversations logins)

# What copy leaves behind. The checkout is DENY-BY-DEFAULT (#1140): only `.git` and what git
# tracks are sent, so gitignored secrets (.local/, settings.local.json, tfstate, vault backups,
# landscapes clones, askpass files ...) never leave the laptop; the list below is a second net.
EXCL_COMMON=(--exclude='__pycache__/')
EXCL_REPOS=(--exclude='node_modules/' --exclude='.materialized/' --exclude='.genesis/'
  --exclude='vault_pass' --exclude='.venv/' --exclude='.terraform/' --exclude='/.claude/worktrees/'
  --exclude='/wt-*/')
EXCL_MEMORY=()
EXCL_CONVERSATIONS=(--exclude='/*/memory/')
EXCL_LOGINS=(--exclude='/projects/' --exclude='/shell-snapshots/' --exclude='/debug/'
  --exclude='/cache/' --exclude='/paste-cache/' --exclude='/telemetry/' --exclude='/statsig/'
  --exclude='/ide/' --exclude='/downloads/' --exclude='/image-cache/' --exclude='/session-env/'
  --exclude='*.log')
# Owner can always work; group read; nobody else. Logins: owner only.
# setuid/setgid are stripped (the server side never keeps them from a laptop).
CHMOD_DATA='Du+rwx,Fu+rw,Dg=rx,Do=,Fg=r,Fo=,Du-s,Dg-s,Fu-s,Fg-s'
CHMOD_LOGINS='Du+rwx,Fu+rw,Dg=,Do=,Fg=,Fo=,Du-s,Dg-s,Fu-s,Fg-s'

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'dev-container-move: %s\n' "$*" >&2; exit 1; }
sq()   { printf "'%s'" "${1//\'/\'\\\'\'}"; }

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
CMD=$1; shift
case "$CMD" in copy|remove|fetch) ;; -h|--help) usage ;; *) usage ;; esac

HOST=${DEVSERVER_HOST:-}; SUSER=${DEVSERVER_USER:-${USER:-}}; SUSER_SET=${DEVSERVER_USER:+1}
REPO_SRC=${DEVCOPY_REPO_DIR:-}; MEM_SRC=${DEVCOPY_MEMORY_DIR:-}
LOGINS_SRC=${DEVCOPY_LOGINS_DIR:-}; CONV_SRC=${DEVCOPY_CONVERSATIONS_DIR:-}
GH_SRC=${DEVCOPY_GH_DIR:-}; VOLUME=${DEVCOPY_VOLUME:-}; IMAGE=${DEVCOPY_IMAGE:-}
DRY=0; NAME=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=${2:?}; shift 2 ;;            --user) SUSER=${2:?}; SUSER_SET=1; shift 2 ;;
    --repo-dir) REPO_SRC=${2:?}; shift 2 ;;    --memory-dir) MEM_SRC=${2:?}; shift 2 ;;
    --logins-dir) LOGINS_SRC=${2:?}; shift 2 ;; --conversations-dir) CONV_SRC=${2:?}; shift 2 ;;
    --gh-dir) GH_SRC=${2:?}; shift 2 ;;        --volume) VOLUME=${2:?}; shift 2 ;;
    --image) IMAGE=${2:?}; shift 2 ;;
    --dry-run) [ "$CMD" = copy ] || die "--dry-run is a copy flag"; DRY=1; shift ;;
    -*) die "unknown flag: $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done
FKIND=""; DEST=""
if [ "$CMD" = fetch ]; then
  [ "${#POS[@]}" -ge 2 ] && [ "${#POS[@]}" -le 3 ] || die "fetch takes: <all|repos|memory|conversations|logins> <container> [<dest>]"
  FKIND=${POS[0]}; NAME=${POS[1]}; DEST=${POS[2]:-${DEVCOPY_FETCH_DIR:-${HOME}/dev-container-fetch}}
  case "$FKIND" in all) FKINDS="${KINDS[*]}" ;; repos|memory|conversations|logins) FKINDS=$FKIND ;;
    *) die "say what to fetch: all, repos, memory, conversations or logins" ;; esac
else
  [ "${#POS[@]}" -le 1 ] || die "one container at a time"
  NAME=${POS[0]:-}
fi

[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || die "give one container name (lower-case letters, digits, dashes)"
# Only containers the estate declares (dev_containers_repos in group_vars/devserver.yml).
# Run from the repo this checks the list. Run from the laptop command (`estate`, #1595), which carries no
# checkout, the file is absent and the check is the SERVER's: its folder guard refuses a name it has no folders for.
DECL_FILE="${REPO_DIR_SELF}/ansible/group_vars/devserver.yml"
if [ -f "$DECL_FILE" ]; then
  DECLARED="$(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*name:[[:space:]]*\([a-z0-9-]*\)[[:space:]]*$/\1/p' "$DECL_FILE")"
  grep -qxF "$NAME" <<<"$DECLARED" || die "'${NAME}' is not a development container this estate declares"
fi

if [ "$DRY" -eq 0 ]; then
  [ -n "$HOST" ] || die "say where the development server is: --host or DEVSERVER_HOST"
  [[ "$HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die "the host is not a plain name or address"
  [[ "$SUSER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "set your server account: --user or DEVSERVER_USER"
fi

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/devcopy.XXXXXX")"
SSHCFG="${WORK}/ssh_config"
STAGE_REMOTE="${STAGE_REL}/${NAME}"; [ "$CMD" != fetch ] || STAGE_REMOTE="${STAGE_REL}/fetch-${NAME}"
PARTIAL=""
cleanup() {
  # Staging on the server holds logins: remove it on every exit path (best effort).
  if [ "$CMD" != remove ] && [ -f "$SSHCFG" ] && [ "${STAGED:-0}" = 1 ]; then
    ssh -F "$SSHCFG" "$TARGET" "rm -rf $(sq "$STAGE_REMOTE")" >/dev/null 2>&1 || \
      log "could not remove ~/${STAGE_REMOTE} on the server; delete it by hand (it holds logins)"
  fi
  [ -z "$PARTIAL" ] || rm -rf "$PARTIAL"   # a half-fetched folder is never left under a dated name
  rm -rf "$WORK"
}
trap cleanup EXIT

TARGET=devserver   # what argv carries: the alias below, or the user's own alias (#1166)
write_ssh_config() {
  local h
  # An address literal is never an alias (and must stay off argv); a name is, if the user's own
  # config resolves it to a different HostName.
  if [[ ! "$HOST" =~ ^[0-9.]+$ && "$HOST" != *:* ]]; then
    h="$(ssh -G -- "$HOST" 2>/dev/null | sed -n 's/^hostname //p' | head -1)" || h=""
    if [ -n "$h" ] && [ "${h,,}" != "${HOST,,}" ]; then TARGET=$HOST; fi
  fi
  {
    if [ "$TARGET" = devserver ]; then printf 'Host devserver\n  HostName %s\n  User %s\n' "$HOST" "$SUSER"
    else printf 'Host %s\n' "$HOST"; [ -z "$SUSER_SET" ] || printf '  User %s\n' "$SUSER"; fi
    printf '  ConnectTimeout 15\n  ControlMaster auto\n  ControlPath %s/cm\n  ControlPersist 10\n' "$WORK"
    printf 'Include ~/.ssh/config\n'; } >"$SSHCFG"
}
rsh() { ssh -F "$SSHCFG" "$@"; }

# A failed connection (host key, network, login) is reported as that, with ssh's own last line,
# never as "no folders" (#1166).
check_connect() {
  local err="${WORK}/ssh.err" why
  rsh "$TARGET" true 2>"$err" && return 0
  why="$(sed '/^[[:space:]]*$/d' "$err" | tail -n1)"
  die "could not connect to ${HOST}: ${why:-ssh failed}"
}

# Run a script as root on the server through one tty, so sudo can ask for the password.
remote_sudo() {   # remote_sudo <script> [args...]
  local script=$1 a cmd; shift
  cmd="sudo -- bash -c $(sq "$script") devcopy"
  for a in "$@"; do cmd+=" $(sq "$a")"; done
  rsh -t "$TARGET" "$cmd"
}

# The server's exclude arrays as bash text, for a script that cannot read ours.
excl_decl() {
  local -n _x="EXCL_${1^^}"; local e
  printf 'EX_%s=(' "$1"; for e in "${EXCL_COMMON[@]}" "${_x[@]}"; do printf ' %s' "$(sq "$e")"; done; printf ' )'
}
if command -v sha256sum >/dev/null 2>&1; then SUMCMD=(sha256sum); else SUMCMD=(shasum -a 256); fi

# Server-side guard shared by both commands: all four folders exist, are real directories under
# /srv/dev and are not symlinks. Exit 3 = this container is not on the server.
# shellcheck disable=SC2016  # runs on the server; its $vars are the server's
GUARD='set -eu; n=$1; root=$2
for k in repos memory conversations logins; do d="$root/$k/$n"
  if [ -L "$d" ] || [ ! -d "$d" ] || [ "$(readlink -f "$d")" != "$d" ]; then
    echo "devcopy: no folder $d on this server" >&2; exit 3; fi; done'

# Copy also needs the container itself (exit 5 = not created yet). Remove tolerates its absence.
COPY_GUARD="${GUARD}
docker inspect \"code-\$n\" >/dev/null 2>&1 || exit 5"

if [ "$CMD" = remove ]; then
  printf 'This DELETES everything imported for "%s" on the development server (repos, memory,\n' "$NAME" >&2
  printf 'conversations, logins) and stops that container. Other containers are not touched.\n' >&2
  printf 'Type the container name to confirm: ' >&2
  read -r ANSWER || ANSWER=""
  [ "$ANSWER" = "$NAME" ] || die "not confirmed; nothing was deleted"
  write_ssh_config; check_connect
  REMOVE_SCRIPT="${GUARD}
if docker inspect \"code-\$n\" >/dev/null 2>&1; then
  docker stop \"code-\$n\" >/dev/null
  [ \"\$(docker inspect -f '{{.State.Running}}' \"code-\$n\")\" != true ] || { echo \"devcopy: code-\$n is still running; nothing deleted\" >&2; exit 4; }
fi
e=\$(mktemp -d)
for k in repos memory conversations logins; do
  rsync -r --delete --omit-dir-times \"\$e\"/ \"\$root/\$k/\$n\"/
done
rmdir \"\$e\"
echo \"devcopy: removed what was imported for \$n; container code-\$n is stopped\" >&2"
  remote_sudo "$REMOVE_SCRIPT" "$NAME" "$REMOTE_ROOT" || die "remove failed or '${NAME}' is not on the server; nothing else was touched"
  log "Done. Revoke the container's tokens at the provider if you will not copy it again."
  exit 0
fi

# ── fetch: server -> desktop (#1589) ──────────────────────────────────────────────────
if [ "$CMD" = fetch ]; then
  # Resolve <dest> without creating it, and refuse one inside this repo (it holds tokens).
  case "/${DEST}/" in */../*) die "no .. in the folder name; give the full path" ;; esac
  case "$DEST" in /*) ;; *) DEST="${PWD}/${DEST}" ;; esac
  anc=$DEST; rest=""
  while [ ! -d "$anc" ] && [ "$anc" != / ]; do rest="/$(basename "$anc")${rest}"; anc=$(dirname "$anc"); done
  DEST_ABS="$(cd "$anc" && pwd -P)${rest}"
  case "${DEST_ABS}/" in "${REPO_DIR_SELF}/"*|"$(cd "$REPO_DIR_SELF" && pwd -P)/"*)
    die "the fetched copy holds logins: choose a folder outside this repository" ;; esac
  write_ssh_config; check_connect
  STAGED=1
  rsh "$TARGET" "rm -rf $(sq "$STAGE_REMOTE") && umask 077 && mkdir -p $(sq "$STAGE_REMOTE") && chmod 700 $(sq "$STAGE_REL") $(sq "$STAGE_REMOTE")" \
    || die "cannot create the staging folder on the server"
  STAGE_HOME="$(rsh "$TARGET" 'cd && pwd' | tail -n1)"
  [[ "$STAGE_HOME" =~ ^/.+ ]] || die "the server did not give a home folder"
  STAGE_ABS="${STAGE_HOME}/${STAGE_REMOTE}"
  [[ "$STAGE_ABS" == */.provisioner-devcopy/* && "$STAGE_ABS" != *..* ]] || die "bad staging path"
  EXDECL=""
  for k in "${KINDS[@]}"; do EXDECL+="$(excl_decl "$k")"$'\n'; done
  # One sudo: read the folders as root into staging (same cut as copy), hash memory, hand it to you.
  # shellcheck disable=SC2016  # runs on the server
  FETCH_BODY='st=$3; kinds=$4
case "$st" in *..*) echo "devcopy: bad staging path" >&2; exit 4;; /?*/.provisioner-devcopy/?*) ;; *) echo "devcopy: bad staging path" >&2; exit 4;; esac
own=${SUDO_USER:-$(id -un)}
# Git never runs as root on a container folder: drop to the folder'"'"'s owner for it.
asown() { if [ "$(id -u)" = 0 ]; then setpriv --reuid="$ou" --regid="$og" --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all "$@"; else "$@"; fi; }
# The container is paused while it is read, so it cannot swap a checked folder for a link.
pz=0; if [ "$(docker inspect -f "{{.State.Running}}" "code-$n" 2>/dev/null)" = true ]; then docker pause "code-$n" >/dev/null && pz=1; fi
trap '"'"'chown -R "$own" "$st"; [ "$pz" = 0 ] || docker unpause "code-$n" >/dev/null 2>&1'"'"' EXIT
for k in $kinds; do
  s="$root/$k/$n"; d="$st/$k"; mkdir -p "$d"
  if [ "$k" = repos ]; then
    [ -d "$s/.git" ] && [ ! -L "$s/.git" ] || { echo "devcopy: $s is not a checkout" >&2; exit 6; }
    ou=$(stat -c %u "$s"); og=$(stat -c %g "$s"); [ "$ou" != 0 ] || { echo "devcopy: $s is owned by root" >&2; exit 6; }
    sr=$(readlink -f "$s"); l="$st/.repos.list"; declare -A okd=()
    # The index is the container'"'"'s: git runs as the folder'"'"'s owner with no config of the container'"'"'s
    # reach (fsmonitor, hooks), and every listed path must really sit under the folder.
    { printf ".git\0"
      asown env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/nonexistent GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git --no-pager -c core.pager=cat -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$s" ls-files -z --cached |
      while IFS= read -r -d "" f; do
        dn=$(dirname -- "$f")
        if [ -z "${okd[$dn]:-}" ]; then
          r=$(readlink -f -- "$s/$dn" 2>/dev/null || true)
          case "$r" in "$sr"|"$sr"/*) okd[$dn]=1 ;; *) okd[$dn]=0 ;; esac
        fi
        [ "${okd[$dn]}" = 1 ] || continue
        if [ -e "$s/$f" ] || [ -L "$s/$f" ]; then printf "%s\0" "$f"; fi; done; } >"$l"
    rsync -rlpt --safe-links --files-from="$l" --from0 "${EX_repos[@]}" "$s/" "$d/"; rm -f "$l"
  else
    declare -n x="EX_$k"; rsync -rlpt --safe-links "${x[@]}" "$s/" "$d/"; unset -n x
  fi
  chown -R "$own" "$d"
done
case " $kinds " in *" memory "*) ( cd "$root/memory/$n" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) >"$st/memory.sha256";; esac
chmod -R u+rwX,go-rwx "$st"
echo "devcopy: staged $kinds for $n" >&2'
  remote_sudo "${EXDECL}${GUARD}
${FETCH_BODY}" "$NAME" "$REMOTE_ROOT" "$STAGE_ABS" "$FKINDS" || die "the folder check or read failed (is '${NAME}' on the server?); nothing was fetched"

  # Bring it down into a hidden folder, then name it by date: never over an older fetch.
  # Only folders made here are locked to you; one that was already there keeps its mode.
  mk=(); [ -d "$DEST_ABS" ] || mk+=("$DEST_ABS"); [ -d "${DEST_ABS}/${NAME}" ] || mk+=("${DEST_ABS}/${NAME}")
  mkdir -p "${DEST_ABS}/${NAME}"; [ "${#mk[@]}" -eq 0 ] || chmod 700 "${mk[@]}"
  PARTIAL="$(umask 077; mktemp -d "${DEST_ABS}/${NAME}/.fetching.XXXXXX")"
  for k in $FKINDS; do
    mkdir -p "${PARTIAL}/${k}"
    rsync -rlpt --safe-links -e "ssh -F '${SSHCFG}'" "${TARGET}:${STAGE_REMOTE}/${k}/" "${PARTIAL}/${k}/" \
      || die "bringing ${k} down failed; staging and the partial folder will be removed"
  done
  have_mem=0; case " $FKINDS " in *" memory "*) have_mem=1 ;; esac
  if [ "$have_mem" = 1 ]; then
    rsync -t -e "ssh -F '${SSHCFG}'" "${TARGET}:${STAGE_REMOTE}/memory.sha256" "${PARTIAL}/memory.sha256" \
      || die "could not read the server's memory checksums; nothing was kept"
  fi
  rsh "$TARGET" "rm -rf $(sq "$STAGE_REMOTE")" && STAGED=0 \
    || log "could not remove ~/${STAGE_REMOTE} on the server; delete it by hand (it holds logins)"
  FINAL="${DEST_ABS}/${NAME}/$(date +%Y-%m-%d)"
  [ ! -e "$FINAL" ] && [ ! -L "$FINAL" ] || FINAL="${DEST_ABS}/${NAME}/$(date +%Y-%m-%d-%H%M%S)"
  i=1; B=$FINAL; while [ -e "$FINAL" ] || [ -L "$FINAL" ]; do i=$((i+1)); FINAL="${B}-${i}"; done
  mv "$PARTIAL" "$FINAL" || die "could not name the fetched folder"
  PARTIAL=""
  log "Fetched ${FKIND} of ${NAME} into ${FINAL}"
  verdict=0
  if [ "$have_mem" = 1 ]; then
    here="$(cd "${FINAL}/memory" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r "${SUMCMD[@]}")"
    log "Memory checksums on the server (the container's own folder):"; sed 's/^/  /' "${FINAL}/memory.sha256" >&2
    log "Memory checksums here:"; printf '%s\n' "$here" | sed 's/^/  /' >&2
    if [ "$here" = "$(cat "${FINAL}/memory.sha256")" ]; then log "MATCH: the memory folder is identical on both sides ($(grep -c . <<<"$here") files)"
    else log "MISMATCH: the memory folder differs between the server and here; fetch again"; verdict=1; fi
  else
    log "Memory was not fetched, so there is no checksum check."
  fi
  log "To restore it: see 'Restore from a fetched copy' in docs/handbook/DEV-CONTAINER-MOVE.md"
  exit "$verdict"
fi

# ── copy: resolve the four sources ────────────────────────────────────────────────────
if [ -z "$REPO_SRC" ]; then
  [ "$NAME" = prometheus ] || die "give the checkout of ${NAME}: --repo-dir"
  REPO_SRC=$REPO_DIR_SELF
fi
[ -d "$REPO_SRC" ] || die "checkout not found: ${REPO_SRC}"
REPO_SRC="$(cd "$REPO_SRC" && pwd)"
[ -n "$MEM_SRC" ] || MEM_SRC="${HOME}/.claude/projects/$(printf '%s' "$REPO_SRC" | sed 's#/#-#g')/memory"
if [ -z "$LOGINS_SRC" ]; then
  [ -n "$VOLUME" ] || VOLUME="${NAME}-devc-claude"
  [ -n "$IMAGE" ] || IMAGE="$(docker images --format '{{.Repository}}' 2>/dev/null | grep -E '^vsc-prometheus-.*-uid$' | head -1 || true)"
  [ -n "$IMAGE" ] || die "cannot read the container's logins: no --logins-dir and no devcontainer image (--image)"
  LOGINS_SRC="${WORK}/claude"; mkdir -p "$LOGINS_SRC"
  docker volume inspect "$VOLUME" >/dev/null 2>&1 || die "docker volume ${VOLUME} does not exist (pass --volume, or --logins-dir)"
  docker run --rm --pull never --network none --read-only --cap-drop ALL \
    -v "${VOLUME}:/v:ro" --entrypoint tar "$IMAGE" -C /v -cf - . | tar -xf - -C "$LOGINS_SRC" \
    || die "could not read docker volume ${VOLUME}"
fi
[ -n "$CONV_SRC" ] || CONV_SRC="${LOGINS_SRC}/projects"
SRC_repos=$REPO_SRC; SRC_memory=$MEM_SRC; SRC_conversations=$CONV_SRC; SRC_logins=$LOGINS_SRC
for k in "${KINDS[@]}"; do v="SRC_$k"; [ -d "${!v}" ] || die "nothing to copy for ${k}: ${!v} does not exist (override with its flag)"; done
# Work in progress = .git plus every file git tracks (modified or not). Untracked files are not sent.
git -C "$REPO_SRC" rev-parse --git-dir >/dev/null 2>&1 || die "${REPO_SRC} is not a git checkout"
REPO_LIST="${WORK}/repos.list"
{ printf '.git\0'
  git -C "$REPO_SRC" ls-files -z --cached | while IFS= read -r -d '' f; do
    if [ -e "${REPO_SRC}/${f}" ] || [ -L "${REPO_SRC}/${f}" ]; then printf '%s\0' "$f"; fi
  done; } >"$REPO_LIST"
files_from() { if [ "$1" = repos ]; then printf '%s\n' "--files-from=${REPO_LIST}" --from0; fi; }
[ -z "$GH_SRC" ] || [ -d "$GH_SRC" ] || die "gh folder not found: ${GH_SRC}"

excl_for() { local -n _e="EXCL_${1^^}"; printf '%s\n' "${EXCL_COMMON[@]}" "${_e[@]}"; }
num() { sed -n "s/^$1: *\([0-9,.]*\).*/\1/p" | head -1 | tr -d ',.'; }

# ── dry run: exactly what rsync would send, local only ──────────────────────────────────
log "Would send to the development server as container '${NAME}':"
legs=("${KINDS[@]}"); [ -z "$GH_SRC" ] || legs+=(gh)
for k in "${legs[@]}"; do
  if [ "$k" = gh ]; then src=$GH_SRC; EXCL_GH=(); else v="SRC_$k"; src=${!v}; fi
  mapfile -t ex < <(excl_for "$k")
  mapfile -t ff < <(files_from "$k")
  out="$(rsync -rlt --safe-links -n --stats "${ff[@]}" "${ex[@]}" "${src}/" "${WORK}/.dry/" 2>&1)" || die "cannot read ${src}"
  sent=$(num 'Number of regular files transferred' <<<"$out"); bytes=$(num 'Total transferred file size' <<<"$out")
  all=$(num 'Total file size' <<<"$out")
  if [ -z "$sent" ] || [ -z "$bytes" ] || [ -z "$all" ]; then die "could not read rsync's summary for ${k}"; fi
  printf '  %-14s %s files, %s bytes   (left behind: %s bytes)  <- %s\n' "$k" "$sent" "$bytes" \
    "$(( all - bytes ))" "$src" >&2
done
log "Left behind on purpose: untracked and gitignored files in the checkout (git add what you"
log "  want kept), node_modules, worktrees, caches, shell snapshots, debug logs, and each"
log "  project's memory inside conversations."
log "Kept: the whole .git, every tracked file (modified or not), .credentials.json, .claude.json, gh/."
[ "$DRY" -eq 0 ] || { log "Dry run: nothing was sent."; exit 0; }

printf 'Send this? Type yes to continue: ' >&2
read -r ANSWER || ANSWER=""
[ "$ANSWER" = yes ] || die "not confirmed; nothing was sent"
write_ssh_config; check_connect

# ── hop 0: is this container on the server? (one sudo prompt) ───────────────────────────
remote_sudo "$COPY_GUARD" "$NAME" "$REMOTE_ROOT" && rc=0 || rc=$?
if [ "$rc" -eq 5 ]; then
  die "the container code-${NAME} does not exist on the server: start it once first (it is created by the estate's converge)"
elif [ "$rc" -eq 255 ]; then
  die "could not connect to ${HOST}: ssh failed during the folder check"
elif [ "$rc" -ne 0 ]; then
  die "'${NAME}' has no folders on the server (is the lap recent enough?); nothing was sent"
fi

# ── hop 1: as you, into a private staging folder ───────────────────────────────────────
STAGED=1
rsh "$TARGET" "umask 077 && mkdir -p $(sq "$STAGE_REMOTE") && chmod 700 $(sq "$STAGE_REL") $(sq "$STAGE_REMOTE") && cd $(sq "$STAGE_REMOTE") && mkdir -p repos memory conversations logins" \
  || die "cannot create the staging folder on the server"
for k in "${legs[@]}"; do
  if [ "$k" = gh ]; then src=$GH_SRC; dst="${STAGE_REMOTE}/logins/gh"; else v="SRC_$k"; src=${!v}; dst="${STAGE_REMOTE}/${k}"; fi
  mapfile -t ex < <(excl_for "$k")
  mapfile -t ff < <(files_from "$k")
  rsync -rlpt --safe-links "${ff[@]}" "${ex[@]}" -e "ssh -F ${SSHCFG}" "${src}/" "${TARGET}:${dst}/" \
    || die "sending ${k} failed; staging will be removed"
done

# ── hop 2: staging -> /srv/dev as root, owned by devcontainer; restart that container ──
APPLY_SCRIPT="${GUARD}
st=\$3
case \"\$st\" in *..*) echo \"devcopy: bad staging path\" >&2; exit 4;; /?*/.provisioner-devcopy/?*) ;; *) echo \"devcopy: bad staging path\" >&2; exit 4;; esac
docker stop \"code-\$n\" >/dev/null
trap 'docker start \"code-\$n\" >/dev/null 2>&1 || true' EXIT
for k in repos memory conversations logins; do
  d=\"\$root/\$k/\$n\"
  if [ \"\$k\" = logins ]; then mode=0700; cm=\"\$CM_LOGINS\"; else mode=0750; cm=\"\$CM_DATA\"; fi
  rsync -rlptog --no-specials --no-devices --safe-links --chown=\"\$OWNER:\$OWNER\" --chmod=\"\$cm\" \"\$st/\$k/\" \"\$d/\"
  chown \"\$OWNER:\$OWNER\" \"\$d\"; chmod \"\$mode\" \"\$d\"
done
rm -rf \"\$st\"
docker start \"code-\$n\" >/dev/null
trap - EXIT
echo \"devcopy: copied; container code-\$n restarted\" >&2"
# sudo may not keep your HOME, so ask the server for the absolute staging path first.
STAGE_HOME="$(rsh "$TARGET" 'cd && pwd' | tail -n1)"
[[ "$STAGE_HOME" =~ ^/.+ ]] || die "the server did not give a home folder"
STAGE_ABS="${STAGE_HOME}/${STAGE_REMOTE}"
[[ "$STAGE_ABS" == */.provisioner-devcopy/* && "$STAGE_ABS" != *..* ]] || die "bad staging path"
APPLY_ENV="OWNER=${REMOTE_OWNER}; CM_DATA=${CHMOD_DATA}; CM_LOGINS=${CHMOD_LOGINS}"
if remote_sudo "${APPLY_ENV}
${APPLY_SCRIPT}" "$NAME" "$REMOTE_ROOT" "$STAGE_ABS"; then
  STAGED=0
else
  die "the final step failed; staging will be removed. Re-run the copy once the cause is fixed"
fi
log "Copied and restarted code-${NAME}."
log "Next: ssh to the server and run: sudo docker exec -it code-${NAME} bash   (then: claude) - see docs/handbook/DEV-CONTAINER-MOVE.md"
