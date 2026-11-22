#!/bin/bash
# Cluster-wide lock on the shared EFS, for steps that must not run on two TAK Server nodes at once
# (issue #7): the first-boot PKI, the Let's Encrypt request and renewal, and the certificate rotations
# of #131, #132, #135, #169, #171 and #172.
#
# Use it in one of two ways:
#   source /opt/tak/scripts/cluster-lock.sh
#   with_cluster_lock <name> <command> [args...]        # <command> can be a shell function
#
#   /opt/tak/scripts/cluster-lock.sh run [--ttl S] [--wait S] <name> -- <command> [args...]
#
# What it does:
# - The lock is the file <CLUSTER_LOCK_DIR>/<name>.lock. It is created by the shell itself with
#   `set -C` (noclobber), which opens it with O_CREAT|O_EXCL: only one node creates it, on EFS (NFSv4)
#   as on a local disk. No external command is part of that step. (An earlier version used `mkdir`; the
#   `mkdir` of uutils coreutils 0.10, the default in Ubuntu 26.04, succeeds for several callers at once.)
#   The file holds "<token> <ttl seconds> <host>".
# - While the command runs, a background loop touches the file every TTL/4 seconds. A lock whose file
#   has not been touched for TTL seconds is expired. A node that dies stops touching it, so the lock
#   can be broken TTL seconds later; a long command needs no long TTL. The loop also releases the lock
#   when the shell that took it has exited.
# - A node that finds an expired lock breaks it under a second, short-lived lock (<name>.lock.breaker,
#   created the same way) and checks again inside that lock. Two waiting nodes therefore cannot both
#   break the lock and then both take it.
# - A node that waits gets the lock only after the holder is done. The command must therefore check
#   again whether its work is still needed ("ca.pem exists now: skip").
#
# Exit status: the command's, or 75 when the lock was not obtained within the wait time, 64 for wrong
# usage, 1 when the lock directory cannot be created.
#
# Settings (environment): CLUSTER_LOCK_DIR (default /opt/tak/certs/files/.locks), CLUSTER_LOCK_TTL
# (default 90 s), CLUSTER_LOCK_WAIT (default 600 s, 0 = do not wait), CLUSTER_LOCK_POLL (default 2 s).
#
# Limits: expiry compares the modification time of the lock file (set by the file system) with the
# time of the waiting node, so the nodes and the file system need roughly the same time (ECS tasks use
# the Amazon Time Sync Service); skew of a few seconds is far below the TTL. If the heartbeat of a
# live holder stalls for longer than the TTL, another node may take the lock; the holder notices on its
# next heartbeat and logs it.
# Not for a command that must keep a lock past a reboot: the lock is released when the holder ends.

_cl_log() { echo "cluster-lock: $*" >&2; }
_cl_now() { date +%s; }
_cl_token_of() { cut -d' ' -f1 "$1" 2> /dev/null || true; }
_cl_host_of() { cut -d' ' -f3 "$1" 2> /dev/null || true; }
# Create <file> with <content>, only if it does not exist (O_EXCL, done by the shell).
_cl_create() { # file content
  (
    set -C
    printf '%s\n' "$2" > "$1"
  ) 2> /dev/null
}
# Whether the lock file is expired: not touched for its TTL. A file without content was just created
# (or its creator died before writing it): 30 s. A file that vanished is never expired (its holder
# released it, and the next node may already have created a new one).
_cl_expired() { # file
  local ttl mtime
  [[ -e "$1" ]] || return 1
  ttl="$(cut -d' ' -f2 "$1" 2> /dev/null || true)"
  [[ "${ttl}" =~ ^[0-9]+$ ]] || ttl=30
  mtime="$(stat -c %Y "$1" 2> /dev/null)" || return 1
  (($(_cl_now) - mtime > ttl))
}
_cl_release() { # file token
  [[ "$(_cl_token_of "$1")" == "$2" ]] && rm -f "$1"
  return 0
}
# Break the lock if it expired. Returns 0 only when it removed it.
_cl_break_if_expired() { # file
  local lock="$1" breaker="$1.breaker" mtime broke=1 seen host
  if mtime="$(stat -c %Y "${breaker}" 2> /dev/null)" && (($(_cl_now) - mtime > 30)); then
    rm -f "${breaker}" # a breaker whose creator died halfway
  fi
  _cl_create "${breaker}" "$(hostname)" || return 1
  if [[ -e "${lock}" ]]; then
    seen="$(_cl_token_of "${lock}")"
    host="$(_cl_host_of "${lock}")"
    # Look once more right before removing: the owner must still be the one that was expired
    if _cl_expired "${lock}" && [[ "$(_cl_token_of "${lock}")" == "${seen}" ]]; then
      _cl_log "breaking the expired lock ${lock##*/} (holder ${host})"
      rm -f "${lock}" && broke=0
    fi
  fi
  rm -f "${breaker}"
  return "${broke}"
}
# Sets _CL_TOKEN. Returns 0, or 75 when the wait time ran out, or 1 when the directory is unusable.
_cl_acquire() { # file ttl wait
  local lock="$1" ttl="$2" wait_s="$3" poll="${CLUSTER_LOCK_POLL:-2}" deadline last_log=0 now
  mkdir -p "${lock%/*}" 2> /dev/null || { _cl_log "cannot create ${lock%/*}"; return 1; }
  deadline=$(($(_cl_now) + wait_s))
  _CL_TOKEN="$(hostname):${BASHPID:-$$}:${RANDOM}${RANDOM}:$(date +%s%N)"
  while true; do
    if _cl_create "${lock}" "${_CL_TOKEN} ${ttl} $(hostname)"; then
      return 0
    fi
    if [[ ! -e "${lock}" ]]; then
      [[ -d "${lock%/*}" && -w "${lock%/*}" ]] || { _cl_log "cannot create ${lock}"; return 1; }
      continue # it was released between our create and the test
    fi
    _cl_break_if_expired "${lock}" && continue
    now="$(_cl_now)"
    if ((now >= deadline)); then
      _cl_log "${lock##*/} is still held by $(_cl_host_of "${lock}") after ${wait_s} s"
      return 75
    fi
    if ((now - last_log >= 30)); then
      _cl_log "waiting for ${lock##*/} (held by $(_cl_host_of "${lock}"))"
      last_log="${now}"
    fi
    sleep "${poll}"
  done
}
# Runs in the background while the command runs.
_cl_heartbeat() { # file token ttl parent_pid
  local lock="$1" token="$2" ttl="$3" parent="$4" interval=$(($3 / 4)) sleeper=""
  ((interval < 1)) && interval=1
  # Stopped by the holder with SIGTERM. The sleep must not outlive it: as a child it would keep the
  # holder's stdout and stderr open, and a caller that reads them through a pipe would wait for it.
  trap '[[ -n "${sleeper}" ]] && kill "${sleeper}" 2> /dev/null; exit 0' TERM
  while kill -0 "${parent}" 2> /dev/null; do
    sleep "${interval}" &
    sleeper=$!
    wait "${sleeper}"
    sleeper=""
    kill -0 "${parent}" 2> /dev/null || break
    if [[ "$(_cl_token_of "${lock}")" != "${token}" ]]; then
      _cl_log "WARNING: ${lock##*/} is no longer ours (the heartbeat was late for more than ${ttl} s)"
      return 0
    fi
    touch -c "${lock}" 2> /dev/null || true
  done
  # The shell that took the lock is gone (the command failed under `set -e`, or it was killed)
  _cl_release "${lock}" "${token}"
}
with_cluster_lock() {
  local name="${1:-}"
  shift || true
  [[ "${1:-}" == "--" ]] && shift
  if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || $# -eq 0 ]]; then
    _cl_log "usage: with_cluster_lock <name> <command> [args...]"
    return 64
  fi
  local ttl="${CLUSTER_LOCK_TTL:-90}" wait_s="${CLUSTER_LOCK_WAIT:-600}"
  local lock="${CLUSTER_LOCK_DIR:-/opt/tak/certs/files/.locks}/${name}.lock" rc=0 hb
  [[ "${ttl}" =~ ^[0-9]+$ && "${wait_s}" =~ ^[0-9]+$ ]] || { _cl_log "TTL and wait must be whole seconds"; return 64; }
  _cl_acquire "${lock}" "${ttl}" "${wait_s}" || return $?
  local token="${_CL_TOKEN}" holder_pid="${BASHPID:-$$}" # taken here: inside `cmd &` BASHPID is the subshell's
  _cl_log "took ${name}.lock"
  # The subshell inherits the caller's EXIT trap and would run it when killed below: clear it first
  (
    trap - EXIT
    _cl_heartbeat "${lock}" "${token}" "${ttl}" "${holder_pid}"
  ) &
  hb=$!
  # Not `cmd || rc=$?`: that would switch `set -e` off inside the command. Under `set -e` a failing command
  # ends the shell, and the heartbeat then releases the lock.
  "$@"
  rc=$?
  kill "${hb}" 2> /dev/null || true
  wait "${hb}" 2> /dev/null || true
  _cl_release "${lock}" "${token}"
  _cl_log "released ${name}.lock"
  return "${rc}"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" != "run" ]]; then
    echo "usage: ${0##*/} run [--ttl SECONDS] [--wait SECONDS] <name> -- <command> [args...]" >&2
    exit 64
  fi
  shift
  while [[ "${1:-}" == --ttl || "${1:-}" == --wait ]]; do
    [[ -n "${2:-}" ]] || { echo "${1} needs a value" >&2; exit 64; }
    if [[ "$1" == --ttl ]]; then CLUSTER_LOCK_TTL="$2"; else CLUSTER_LOCK_WAIT="$2"; fi
    shift 2
  done
  with_cluster_lock "$@"
  exit $?
fi
