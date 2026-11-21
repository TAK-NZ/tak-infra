#!/bin/bash
# Tests for docker-container/scripts/cluster-lock.sh (#7). Needs only bash and coreutils.
# Several processes on one machine stand in for several TAK Server nodes sharing the EFS: the lock is a
# directory, and mkdir is atomic on a local disk like on EFS.
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
STATE="${WORK}/pki.done"
RUNS="${WORK}/pki.runs"
: > "${RUNS}"
bootstrap_once() { [[ -e "${STATE}" ]] && return 0; sleep 0.5; echo run >> "${RUNS}"; : > "${STATE}"; }
export -f bootstrap_once
export STATE RUNS
for i in 1 2 3 4; do
  "${LIB}" run --wait 60 pki -- bash -c "$(declare -f bootstrap_once); bootstrap_once" 2> /dev/null &
done
wait
assert_eq "four fresh nodes: the work was done once" "$(wc -l < "${RUNS}")" "1"

echo "== a lock directory that vanishes under a waiter never looks expired"
# The holder releases between the waiter's "does it exist" and "when does it expire". A fresh lock that the
# next node creates right after must not be broken because of that.
now=$(date +%s)
exp="$(_cl_expiry_of "${WORK}/gone.lock")"
assert_eq "the expiry of a missing lock is not in the past" "$((exp >= now))" "1"
mt="$(_cl_mtime "${WORK}/gone.lock.breaker")"
assert_eq "the age of a missing breaker is not old" "$((now - mt <= 1))" "1"
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
mkdir -p "${CLUSTER_LOCK_DIR}/dead.lock"
printf 'ghost:1:1:1 %s deadhost\n' "$(($(date +%s) + 3))" > "${CLUSTER_LOCK_DIR}/dead.lock/owner"
start=$(date +%s)
"${LIB}" run --wait 20 dead -- echo took-over 2> "${WORK}/err" > "${WORK}/out"
assert_eq "the waiter got the lock after the expiry" "$(cat "${WORK}/out")" "took-over"
elapsed=$(($(date +%s) - start))
assert_eq "...not before the expiry, not long after (${elapsed} s)" "$((elapsed >= 2 && elapsed <= 8))" "1"
assert_contains "the break is logged with the dead holder" "$(cat "${WORK}/err")" "breaking the expired lock dead.lock (holder deadhost)"
# a lock directory without an owner file (creator died between mkdir and writing it) expires 30 s after creation
mkdir -p "${CLUSTER_LOCK_DIR}/noowner.lock"
touch -d '2 minutes ago' "${CLUSTER_LOCK_DIR}/noowner.lock"
"${LIB}" run --wait 5 noowner -- true 2> /dev/null
assert_eq "an old lock directory without an owner file is broken" "$?" "0"
mkdir -p "${CLUSTER_LOCK_DIR}/fresh.lock"
"${LIB}" run --wait 0 fresh -- true 2> /dev/null
assert_eq "a just created lock directory without an owner file is respected" "$?" "75"
find "${CLUSTER_LOCK_DIR}/fresh.lock" -delete

echo "== several waiters on one expired lock: one breaks it, they run one after the other"
mkdir -p "${CLUSTER_LOCK_DIR}/race.lock"
printf 'ghost:1:1:1 %s deadhost\n' "$(($(date +%s) - 100))" > "${CLUSTER_LOCK_DIR}/race.lock/owner"
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
[[ -d "${CLUSTER_LOCK_DIR}/killed.lock" ]] && pass "the lock is held while the shell lives" || fail "the lock is held while the shell lives"
kill -KILL "${victim}" 2> /dev/null
wait "${victim}" 2> /dev/null
for _ in $(seq 1 30); do [[ -e "${CLUSTER_LOCK_DIR}/killed.lock" ]] || break; sleep 0.2; done
assert_no_dir "a killed shell: the heartbeat released the lock" "${CLUSTER_LOCK_DIR}/killed.lock"
pkill -f '^sleep 60$' 2> /dev/null

echo "== the caller's EXIT trap runs once, not when the heartbeat is stopped"
TRAPLOG="${WORK}/trap.log"
: > "${TRAPLOG}"
bash -c "trap 'echo exit-trap >> '${TRAPLOG}'' EXIT; source '${LIB}'; with_cluster_lock traps true; with_cluster_lock traps true" 2> /dev/null
assert_eq "the EXIT trap of the caller ran once" "$(grep -c exit-trap "${TRAPLOG}")" "1"

echo "== a lock that was taken over is not released by its old holder"
LOST="${CLUSTER_LOCK_DIR}/lost.lock"
slow() { sleep 3; }
CLUSTER_LOCK_TTL=4 with_cluster_lock lost slow 2> "${WORK}/err" &
sleep 1
printf 'someone-else:2:2:2 %s otherhost\n' "$(($(date +%s) + 60))" > "${LOST}/owner"
wait $!
assert_eq "the new owner's lock is still there" "$(cut -d' ' -f1 "${LOST}/owner" 2> /dev/null)" "someone-else:2:2:2"
assert_contains "the old holder noticed" "$(cat "${WORK}/err")" "no longer ours"
find "${LOST}" -delete

echo "== start-tak.sh wraps the certbot cron job"
CRON="${WORK}/certbot.cron"
# the line of the Ubuntu 22.04 certbot package (the base image of the container is eclipse-temurin:17-jammy)
cat > "${CRON}" <<'EOF2'
0 */12 * * * root test -x /usr/bin/certbot -a \! -d /run/systemd/system && perl -e 'sleep int(rand(43200))' && certbot -q renew
EOF2
SED_CMD="$(grep -o "sed -i 's#&& certbot -q renew#[^']*'" "${REPO_ROOT}/docker-container/scripts/start-tak.sh" | head -1)"
[[ -n "${SED_CMD}" ]] && pass "the sed command is in start-tak.sh" || fail "the sed command is in start-tak.sh"
eval "${SED_CMD} '${CRON}'"
assert_contains "the renewal runs through cluster-lock.sh without waiting" "$(cat "${CRON}")" "&& /opt/tak/scripts/cluster-lock.sh run --wait 0 certbot-renew -- certbot -q renew"
assert_contains "the random sleep stays outside the lock" "$(cat "${CRON}")" "perl -e 'sleep int(rand(43200))' && /opt/tak/scripts/cluster-lock.sh"
assert_eq "the cron line is still one line" "$(wc -l < "${CRON}")" "1"
assert_eq "start-tak.sh skips a file that is already wrapped (it greps for cluster-lock.sh)" "$(grep -c 'grep -q "cluster-lock.sh"' "${REPO_ROOT}/docker-container/scripts/start-tak.sh")" "1"

echo
echo "passed ${PASS}, failed ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
