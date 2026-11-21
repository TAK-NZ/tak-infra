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
# - The lock is the directory <CLUSTER_LOCK_DIR>/<name>.lock. `mkdir` is atomic on EFS (NFSv4), so only
#   one node creates it. The directory holds a file `owner`: "<token> <expiry epoch> <host>".
# - While the command runs, a background loop pushes the expiry forward every TTL/4 seconds. A node that
#   dies stops doing so, and the lock becomes breakable TTL seconds later. A long command therefore does
#   not need a long TTL. The loop also releases the lock when the shell that took it has exited.
# - A node that finds an expired lock breaks it under a second, short-lived lock (<name>.lock.breaker),
#   and checks the expiry again inside that lock. Two waiting nodes therefore cannot both break the
#   lock and then both take it.
# - A node that waits gets the lock only after the holder is done. The command must therefore check
#   again whether its work is still needed ("ca.pem exists now: skip").
#
# Exit status: the command's, or 75 when the lock was not obtained within the wait time, 64 for wrong
# usage, 1 when the lock directory cannot be created.
#
# Settings (environment): CLUSTER_LOCK_DIR (default /opt/tak/certs/files/.locks), CLUSTER_LOCK_TTL
# (default 90 s), CLUSTER_LOCK_WAIT (default 600 s, 0 = do not wait), CLUSTER_LOCK_POLL (default 2 s).
#
# Limits: the expiry is a wall-clock time written by the holder and compared by the waiters, so the
# nodes need roughly the same time (ECS tasks use the Amazon Time Sync Service); skew of a few seconds
# is far below the TTL. If the heartbeat of a live holder stalls for longer than the TTL, another node
# may take the lock; the holder notices on its next heartbeat and logs it.
# Not for a command that must keep a lock past a reboot: the lock is released when the holder ends.

_cl_log() { echo "cluster-lock: $*" >&2; }
_cl_now() { date +%s; }
# A directory that vanished between the test and this call (its holder released it) counts as just
# touched, never as old: "old" would make a fresh lock of the next node look expired.
_cl_mtime() { stat -c %Y "$1" 2> /dev/null || _cl_now; }
_cl_token_of() { cut -d' ' -f1 "$1/owner" 2> /dev/null || true; }
_cl_host_of() { cut -d' ' -f3 "$1/owner" 2> /dev/null || true; }
# Epoch second after which the lock directory counts as abandoned. A directory without an owner file
# was just created (or its creator died before writing the file): give it 30 s.
_cl_expiry_of() {
  local exp
  exp="$(cut -d' ' -f2 "$1/owner" 2> /dev/null || true)"
  if [[ "${exp}" =~ ^[0-9]+$ ]]; then
    echo "${exp}"
  else
    echo $(($(_cl_mtime "$1") + 30))
  fi
}
_cl_write_owner() { # lockdir token ttl
  local tmp="$1/owner.$$.${RANDOM}.tmp"
  { printf '%s %s %s\n' "$2" $(($(_cl_now) + $3)) "$(hostname)" > "${tmp}" && mv -f "${tmp}" "$1/owner"; } 2> /dev/null \
    || { rm -f "${tmp}" 2> /dev/null; return 1; }
}
_cl_remove() { # lockdir
  rm -f "$1"/owner "$1"/owner.*.tmp 2> /dev/null
  rmdir "$1" 2> /dev/null
}
_cl_release() { # lockdir token
  [[ "$(_cl_token_of "$1")" == "$2" ]] && _cl_remove "$1"
  return 0
}
# Break the lock if it expired. Returns 0 only when it removed it.
_cl_break_if_expired() { # lockdir
  local lock="$1" breaker="$1.breaker" broke=1
  if [[ -d "${breaker}" ]] && (($(_cl_now) - $(_cl_mtime "${breaker}") > 30)); then
    rmdir "${breaker}" 2> /dev/null || true # a breaker that died halfway
  fi
  mkdir "${breaker}" 2> /dev/null || return 1
  if [[ -d "${lock}" ]]; then
    local seen host expiry
    seen="$(_cl_token_of "${lock}")"
    host="$(_cl_host_of "${lock}")"
    expiry="$(_cl_expiry_of "${lock}")"
    # Look once more right before removing: the owner must still be the one that was expired
    if (($(_cl_now) > expiry)) && [[ "$(_cl_token_of "${lock}")" == "${seen}" ]]; then
      _cl_log "breaking the expired lock ${lock##*/} (holder ${host})"
      _cl_remove "${lock}" && broke=0
    fi
  fi
  rmdir "${breaker}" 2> /dev/null || true
  return "${broke}"
}
# Sets _CL_TOKEN. Returns 0, or 75 when the wait time ran out, or 1 when the directory is unusable.
_cl_acquire() { # lockdir ttl wait
  local lock="$1" ttl="$2" wait_s="$3" poll="${CLUSTER_LOCK_POLL:-2}" deadline last_log=0 now
  mkdir -p "${lock%/*}" 2> /dev/null || { _cl_log "cannot create ${lock%/*}"; return 1; }
  deadline=$(($(_cl_now) + wait_s))
  _CL_TOKEN="$(hostname):${BASHPID:-$$}:${RANDOM}${RANDOM}:$(date +%s%N)"
  while true; do
    if mkdir "${lock}" 2> /dev/null; then
      _cl_write_owner "${lock}" "${_CL_TOKEN}" "${ttl}" || true
      return 0
    fi
    if [[ ! -d "${lock}" ]]; then
      [[ -d "${lock%/*}" && -w "${lock%/*}" ]] || { _cl_log "cannot create ${lock}"; return 1; }
      continue # it was released between our mkdir and the test
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
_cl_heartbeat() { # lockdir token ttl parent_pid
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
    _cl_write_owner "${lock}" "${token}" "${ttl}" || true
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
