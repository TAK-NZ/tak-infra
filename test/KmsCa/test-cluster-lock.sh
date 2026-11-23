#!/bin/bash
# Tests for docker-container/scripts/cluster-lock.sh (#7). Needs only bash and coreutils (GNU or uutils:
# the GitHub runner image ubuntu-26.04 has uutils, whose mkdir is not exclusive under concurrency).
# Several processes on one machine stand in for several TAK Server nodes sharing the EFS: the lock is a
# directory; the lock is a file created with O_EXCL, which is atomic on a local disk like on EFS.
# Run from the repository root:  test/KmsCa/test-cluster-lock.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO_ROOT}/docker-container/scripts/cluster-lock.sh"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete 2> /dev/null' EXIT
export CLUSTER_LOCK_DIR="${WORK}/locks"
export CLUSTER_LOCK_POLL=0.2
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "       $2"; }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1" "expected to contain '$3', got '$2'"; }
assert_no_dir() { [[ ! -e "$2" ]] && pass "$1" || fail "$1" "must not exist: $2"; }

echo "== basics"
out="$("${LIB}" run basic -- bash -c 'echo ran; exit 0' 2> "${WORK}/err")"
assert_eq "run: the command runs and its output passes through" "${out}" "ran"
assert_no_dir "run: the lock is released afterwards" "${CLUSTER_LOCK_DIR}/basic.lock"
"${LIB}" run basic -- bash -c 'exit 7' 2> /dev/null
assert_eq "run: the exit status of the command is returned" "$?" "7"
assert_no_dir "run: the lock is released after a failing command" "${CLUSTER_LOCK_DIR}/basic.lock"
"${LIB}" run 'bad name' -- true 2> /dev/null
assert_eq "run: an invalid lock name is refused" "$?" "64"
"${LIB}" run basic 2> /dev/null
assert_eq "run: no command is refused" "$?" "64"
"${LIB}" frob 2> /dev/null
assert_eq "run: an unknown subcommand is refused" "$?" "64"
CLUSTER_LOCK_TTL=abc "${LIB}" run basic -- true 2> /dev/null
assert_eq "run: a TTL that is not a number is refused" "$?" "64"

echo "== a caller that reads the output through a pipe is not held up by the heartbeat"
# Default TTL 90 s means a 22 s heartbeat sleep. A sleep that outlived the command kept the pipe open.
start=$(date +%s)
out="$(CLUSTER_LOCK_TTL=90 "${LIB}" run pipe -- echo piped 2>&1)"
elapsed=$(($(date +%s) - start))
assert_contains "the output reaches the caller" "${out}" "piped"
assert_eq "...and it comes back at once (${elapsed} s)" "$((elapsed <= 3))" "1"

echo "== sourced function"
# shellcheck disable=SC1090
source "${LIB}"
MARK=""
set_mark() { MARK="set by $1"; }
with_cluster_lock fn set_mark "the function" 2> /dev/null
assert_eq "with_cluster_lock: a shell function runs in the current shell" "${MARK}" "set by the function"
with_cluster_lock fn -- set_mark "after --" 2> /dev/null
assert_eq "with_cluster_lock: -- before the command is accepted" "${MARK}" "set by after --"
assert_no_dir "with_cluster_lock: released" "${CLUSTER_LOCK_DIR}/fn.lock"
cmd_fails() { return 3; }
with_cluster_lock fn cmd_fails 2> /dev/null
assert_eq "with_cluster_lock: a failing function returns its status" "$?" "3"

echo "== mutual exclusion"
# Six "nodes" each add start and end lines with a pause between. Under the lock the lines never interleave.
LOG="${WORK}/order.log"
: > "${LOG}"
for i in 1 2 3 4 5 6; do
  "${LIB}" run --wait 60 mutex -- bash -c "echo start-$i >> '${LOG}'; sleep 0.4; echo end-$i >> '${LOG}'" 2> /dev/null &
done
wait
assert_eq "six contenders all ran" "$(grep -c '^end-' "${LOG}")" "6"
ok=1
prev=""
while read -r line; do
  case "${line}" in
    start-*) [[ -z "${prev}" || "${prev}" == end-* ]] || ok=0 ;;
    end-*) [[ "${prev}" == "start-${line#end-}" ]] || ok=0 ;;
  esac
  prev="${line}"
done < "${LOG}"
assert_eq "the runs did not overlap" "${ok}" "1"
assert_no_dir "the lock is gone after the last one" "${CLUSTER_LOCK_DIR}/mutex.lock"

echo "== the first-boot pattern: a waiting node sees the finished work and skips it"
# Repeated: a failure here has shown up in CI only now and then. On a failure the trace shows who ran when,
# and what every contender's lock said.
RUNS="${WORK}/pki.runs"
TRACE="${WORK}/pki.trace"
bootstrap_once() {
  [[ -e "${STATE}" ]] && { echo "$(date +%s.%N) $$ skip" >> "${TRACE}"; return 0; }
  echo "$(date +%s.%N) $$ start" >> "${TRACE}"
  sleep 0.5
  echo run >> "${RUNS}"
  : > "${STATE}"
  echo "$(date +%s.%N) $$ end" >> "${TRACE}"
}
export -f bootstrap_once
export RUNS TRACE
bad=0
for round in $(seq 1 20); do
  STATE="${WORK}/pki.done.${round}"
  export STATE
  : > "${RUNS}"
  : > "${TRACE}"
  for i in 1 2 3 4; do
    "${LIB}" run --wait 60 "pki${round}" -- bash -c "$(declare -f bootstrap_once); bootstrap_once" 2> "${WORK}/pki.err.${i}" &
  done
  wait
  if [[ "$(wc -l < "${RUNS}")" != 1 ]]; then
    bad=$((bad + 1))
    echo "       round ${round}: the work ran $(wc -l < "${RUNS}") times"
    echo "       trace (time pid event):"
    sed 's/^/         /' "${TRACE}"
    for i in 1 2 3 4; do echo "       contender ${i} said:"; sed 's/^/         /' "${WORK}/pki.err.${i}"; done
    echo "       lock dir: $(ls -a "${CLUSTER_LOCK_DIR}" | tr '\n' ' ')"
  fi
done
assert_eq "four fresh nodes, 20 rounds: the work was done once each time" "${bad}" "0"

echo "== a lock file that vanishes under a waiter never looks expired"
# The holder releases between the waiter's "does it exist" and "is it expired". A fresh lock that the
# next node creates right after must not be broken because of that.
_cl_expired "${WORK}/gone.lock" && fail "a missing lock file is not expired" || pass "a missing lock file is not expired"
printf 'x:1:1:1 3 h\n' > "${WORK}/fresh1.lock"
_cl_expired "${WORK}/fresh1.lock" && fail "a lock file touched now is not expired" || pass "a lock file touched now is not expired"
touch -d '10 seconds ago' "${WORK}/fresh1.lock"
_cl_expired "${WORK}/fresh1.lock" && pass "...and is expired after its TTL (3 s) without a touch" || fail "expired after its TTL"
: > "${WORK}/empty.lock"
_cl_expired "${WORK}/empty.lock" && fail "an empty lock file just created is not expired" || pass "an empty lock file just created is not expired"
touch -d '2 minutes ago' "${WORK}/empty.lock"
_cl_expired "${WORK}/empty.lock" && pass "an empty lock file is expired after 30 s" || fail "empty lock file expiry"
# A stress run of the first-boot pattern: eight contenders, tight polling, many rounds
RUNS="${WORK}/stress.runs"
bad=0
for round in $(seq 1 15); do
  STATE="${WORK}/stress.done.${round}"
  : > "${RUNS}"
  export STATE RUNS
  for i in 1 2 3 4 5 6 7 8; do
    CLUSTER_LOCK_POLL=0.01 "${LIB}" run --wait 60 "stress${round}" -- bash -c "$(declare -f bootstrap_once); bootstrap_once" 2> /dev/null &
  done
  wait
  [[ "$(wc -l < "${RUNS}")" == 1 ]] || bad=$((bad + 1))
done
assert_eq "15 rounds of eight contenders: the work ran once each time" "${bad}" "0"

echo "== not getting the lock"
"${LIB}" run --wait 30 held -- sleep 4 2> /dev/null &
holder=$!
sleep 1
start=$(date +%s)
"${LIB}" run --wait 0 held -- true 2> "${WORK}/err"
rc=$?
assert_eq "--wait 0 on a held lock: status 75" "${rc}" "75"
assert_eq "--wait 0 does not wait" "$(($(date +%s) - start < 2))" "1"
assert_contains "the message names the holder" "$(cat "${WORK}/err")" "still held by"
"${LIB}" run --wait 1 held -- true 2> /dev/null
assert_eq "--wait 1 on a lock held for longer: status 75" "$?" "75"
wait "${holder}"
"${LIB}" run --wait 0 held -- true 2> /dev/null
assert_eq "the lock is free again after the holder ended" "$?" "0"

echo "== the heartbeat keeps a long command's lock"
# TTL 4 s, the command takes 9 s: without the heartbeat the lock would expire at 4 s
CLUSTER_LOCK_TTL=4 "${LIB}" run long -- sleep 9 2> /dev/null &
holder=$!
sleep 7
CLUSTER_LOCK_TTL=4 "${LIB}" run --wait 0 long -- true 2> "${WORK}/err"
assert_eq "after 7 s (TTL 4 s) the lock is still held: status 75" "$?" "75"
assert_eq "no break message" "$(grep -c breaking "${WORK}/err")" "0"
wait "${holder}"

echo "== a node that died: the lock expires and is broken"
# A holder killed with SIGKILL together with its heartbeat leaves the lock directory behind
printf 'ghost:1:1:1 3 deadhost\n' > "${CLUSTER_LOCK_DIR}/dead.lock"
start=$(date +%s)
"${LIB}" run --wait 20 dead -- echo took-over 2> "${WORK}/err" > "${WORK}/out"
assert_eq "the waiter got the lock after the expiry" "$(cat "${WORK}/out")" "took-over"
elapsed=$(($(date +%s) - start))
assert_eq "...not before the expiry, not long after (${elapsed} s)" "$((elapsed >= 2 && elapsed <= 8))" "1"
assert_contains "the break is logged with the dead holder" "$(cat "${WORK}/err")" "breaking the expired lock dead.lock (holder deadhost)"
# an empty lock file (creator died between creating it and writing it) expires 30 s after creation
: > "${CLUSTER_LOCK_DIR}/noowner.lock"
touch -d '2 minutes ago' "${CLUSTER_LOCK_DIR}/noowner.lock"
"${LIB}" run --wait 5 noowner -- true 2> /dev/null
assert_eq "an old empty lock file is broken" "$?" "0"
: > "${CLUSTER_LOCK_DIR}/fresh.lock"
"${LIB}" run --wait 0 fresh -- true 2> /dev/null
assert_eq "a just created empty lock file is respected" "$?" "75"
find "${CLUSTER_LOCK_DIR}/fresh.lock" -delete

echo "== several waiters on one expired lock: one breaks it, they run one after the other"
printf 'ghost:1:1:1 5 deadhost\n' > "${CLUSTER_LOCK_DIR}/race.lock"
touch -d '100 seconds ago' "${CLUSTER_LOCK_DIR}/race.lock"
LOG="${WORK}/race.log"
: > "${LOG}"
for i in 1 2 3 4 5 6; do
  "${LIB}" run --wait 60 race -- bash -c "echo start-$i >> '${LOG}'; sleep 0.3; echo end-$i >> '${LOG}'" 2> /dev/null &
done
wait
ok=1
prev=""
while read -r line; do
  case "${line}" in
    start-*) [[ -z "${prev}" || "${prev}" == end-* ]] || ok=0 ;;
    end-*) [[ "${prev}" == "start-${line#end-}" ]] || ok=0 ;;
  esac
  prev="${line}"
done < "${LOG}"
assert_eq "all six ran" "$(grep -c '^end-' "${LOG}")" "6"
assert_eq "none overlapped" "${ok}" "1"
assert_no_dir "no breaker lock is left" "${CLUSTER_LOCK_DIR}/race.lock.breaker"

echo "== the holder's shell ends without releasing (set -e, killed)"
# Under set -e a failing command ends the shell at once. The heartbeat sees that and releases the lock.
bash -c "set -e; source '${LIB}'; CLUSTER_LOCK_TTL=4 with_cluster_lock exits false; echo not-reached" 2> /dev/null > "${WORK}/out"
assert_eq "set -e: the failing command ended the shell" "$(cat "${WORK}/out")" ""
for _ in $(seq 1 30); do [[ -e "${CLUSTER_LOCK_DIR}/exits.lock" ]] || break; sleep 0.2; done
assert_no_dir "set -e: the heartbeat released the lock within a few seconds" "${CLUSTER_LOCK_DIR}/exits.lock"
bash -c "set -e; source '${LIB}'; CLUSTER_LOCK_TTL=4 with_cluster_lock killed sleep 60" 2> /dev/null &
victim=$!
sleep 1
[[ -e "${CLUSTER_LOCK_DIR}/killed.lock" ]] && pass "the lock is held while the shell lives" || fail "the lock is held while the shell lives"
kill -KILL "${victim}" 2> /dev/null
wait "${victim}" 2> /dev/null
for _ in $(seq 1 30); do [[ -e "${CLUSTER_LOCK_DIR}/killed.lock" ]] || break; sleep 0.2; done
assert_no_dir "a killed shell: the heartbeat released the lock" "${CLUSTER_LOCK_DIR}/killed.lock"
pkill -f '^sleep 60$' 2> /dev/null

echo "== the caller's EXIT trap runs once, not when the heartbeat is stopped"
TRAPLOG="${WORK}/trap.log"
# a command that ends at once is the worst case: the kill of the heartbeat arrives while its shell starts (a flake in CI
# until the trap was cleared before the fork); 40 rounds
bad=0
for _ in $(seq 1 40); do
  : > "${TRAPLOG}"
  bash -c "trap 'echo exit-trap >> '${TRAPLOG}'' EXIT; source '${LIB}'; with_cluster_lock traps true; with_cluster_lock traps true" 2> /dev/null
  [[ "$(grep -c exit-trap "${TRAPLOG}")" == "1" ]] || bad=$((bad + 1))
done
assert_eq "the EXIT trap of the caller ran once, in 40 rounds" "${bad}" "0"

echo "== a lock that was taken over is not released by its old holder"
LOST="${CLUSTER_LOCK_DIR}/lost.lock"
slow() { sleep 3; }
CLUSTER_LOCK_TTL=4 with_cluster_lock lost slow 2> "${WORK}/err" &
sleep 1
printf 'someone-else:2:2:2 60 otherhost\n' > "${LOST}"
wait $!
assert_eq "the new owner's lock is still there" "$(cut -d' ' -f1 "${LOST}" 2> /dev/null)" "someone-else:2:2:2"
assert_contains "the old holder noticed" "$(cat "${WORK}/err")" "no longer ours"
find "${LOST}" -delete

echo
echo "passed ${PASS}, failed ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
