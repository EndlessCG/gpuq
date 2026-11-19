#!/usr/bin/env bash
# gpuq's tests: the real gpuq and qtop against a fake nvidia-smi (tests/bin), no GPU needed.
# Run: tests/run.sh
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
export PATH="$ROOT/tests/bin:$ROOT/bin:$PATH"
export GPUQ_POLL_SECONDS=1 GPUQ_CHECK_SECONDS=1
pass=0 fail=0
dirs=()
trap 'rm -rf "${dirs[@]}"' EXIT

setup() {  # $1..: memory used (MiB) per card; one card per argument
  export GPUQ_DIR; GPUQ_DIR=$(mktemp -d); dirs+=("$GPUQ_DIR")
  export FAKE_GPUS="$GPUQ_DIR/gpus.csv" FAKE_APPS="$GPUQ_DIR/apps.csv"
  : > "$FAKE_GPUS"; : > "$FAKE_APPS"
  local i=0 m
  for m in "$@"; do
    echo "$i,GPU-$i,NVIDIA Test,$m,81920,0,30,60,400" >> "$FAKE_GPUS"; i=$((i+1))
  done
}
check() {  # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then pass=$((pass+1)); echo "ok    $name"; else fail=$((fail+1)); echo "FAIL  $name"; fi
}
leased() { gpuq run "$@" -- bash -c 'echo "$CUDA_VISIBLE_DEVICES"' 2>/dev/null; }

setup 0 0 0 0
check "a job gets the first free card" test "$(leased)" = 0
check "-n 2 gets two cards" test "$(leased -n 2)" = "0,1"

setup 20000 0 0 0
check "a busy card (memory in use) is skipped" test "$(leased)" = 1

setup 0 0 0 0
gpuq cap --exclude "0 1" >/dev/null
check "excluded cards are never leased" test "$(leased)" = 2
check "cap shows the exclusion" bash -c 'gpuq cap | grep -q "excluded=0 1"'
gpuq cap --exclude "" >/dev/null
check "an empty --exclude clears it" test "$(leased)" = 0

setup 0 0
check "--gpus narrows the choice" test "$(leased --gpus "1")" = 1

setup 0 0
gpuq run -- sleep 3 2>/dev/null &
sleep 1
check "a second job gets a different card while the first holds one" test "$(leased)" = 1
wait

setup 0
start=$(date +%s)
gpuq run -- sleep 2 2>/dev/null &
sleep 0.5
second=$(leased)
waited=$(( $(date +%s) - start ))
check "with one card, the next job waits for it" test "$second" = 0 -a "$waited" -ge 2
wait

setup 0 0
gpuq cap --total 1 >/dev/null
gpuq run -- sleep 2 2>/dev/null &
sleep 0.5
start=$(date +%s)
leased >/dev/null
check "--total caps how many cards your jobs hold" test $(( $(date +%s) - start )) -ge 1
wait

setup 0
order="$GPUQ_DIR/order"
gpuq run -- sleep 2 2>/dev/null &
sleep 0.3
gpuq run --low -- bash -c "echo low >> $order" 2>/dev/null &
sleep 0.3
gpuq run -- bash -c "echo normal >> $order" 2>/dev/null &
wait
check "a low job waits while a normal job waits" test "$(head -1 "$order")" = normal

setup 0
order="$GPUQ_DIR/order"
gpuq run -- sleep 2 2>/dev/null &
sleep 0.3
gpuq run -- bash -c "echo first-come >> $order" 2>/dev/null &
sleep 0.3
gpuq run --high -- bash -c "echo high >> $order" 2>/dev/null &
wait
check "a --high job goes ahead of earlier waiting jobs" test "$(head -1 "$order")" = high

setup 0 0
gpuq run --note "smoke test" --eta 5m -- sleep 3 2>/dev/null &
sleep 1
check "status lists the lease with its note" bash -c 'gpuq status | grep -q "lease pid .* smoke test · eta 5m"'
check "qtop --once draws the cards and the lease" bash -c 'qtop --once | grep -q "lease"'
wait
check "a finished job's cards are free again" test "$(leased -n 2)" = "0,1"

setup 0
check "a bad --eta is refused" bash -c '! gpuq run --eta 5x -- true 2>/dev/null'
check "a bad --total is refused" bash -c '! gpuq cap --total lots 2>/dev/null'

setup 0
sleep 30 & holder=$!
check "acquire leases for a given PID" test "$(gpuq acquire 1 --owner $holder)" = 0
gpuq release --owner $holder
check "release frees it at once" bash -c '! ls "$GPUQ_DIR"/gpu_reservations/gpu* >/dev/null 2>&1'
kill $holder

setup 0
gpuq run -- sleep 30 2>/dev/null & job=$!
sleep 1
check "the job runs as the lease's own PID" bash -c "[ \"\$(cat \$GPUQ_DIR/gpu_reservations/gpu0)\" = $job ] && ps -o args= -p $job | grep -q '^sleep 30'"
kill -9 $job; wait $job 2>/dev/null
check "a job killed with -9 frees its card" test "$(leased)" = 0

setup 0
gpuq run -- sleep 30 2>/dev/null & holder=$!
sleep 0.5
gpuq run -- true 2>/dev/null & waiter=$!
sleep 1.5
kill $waiter; wait $waiter 2>/dev/null
sleep 2
check "a waiting job that is killed leaves the queue" bash -c '! ls "$GPUQ_DIR"/gpu_waiting/* >/dev/null 2>&1'
check "and no wait loop polls on after it" bash -c "! pgrep -af '[g]puq run -- true' | grep -v pgrep"
kill $holder; wait $holder 2>/dev/null

setup 0 0
gpuq cap --exclude "GPU-0" >/dev/null
check "a card can be excluded by UUID" test "$(leased)" = 1
check "--gpus naming only excluded cards fails at once" bash -c '! timeout 5 gpuq run --gpus 0 -- true 2>/dev/null'
gpuq cap --exclude "" >/dev/null
check "--gpus takes a comma list" test "$(leased -n 2 --gpus 1,0)" = "1,0"

setup 0
gpuq pause --note "maintenance" >/dev/null
gpuq run -- bash -c "echo ran > $GPUQ_DIR/ran" 2>/dev/null & job=$!
sleep 2.5
check "a paused queue leases nothing" test ! -e "$GPUQ_DIR/ran"
check "status shows the pause" bash -c 'gpuq status | grep -q "PAUSED since .*maintenance"'
gpuq unpause >/dev/null
wait $job
check "after unpause the job runs" test -e "$GPUQ_DIR/ran"

setup 0
order="$GPUQ_DIR/order"
gpuq run -- sleep 2 2>/dev/null &
sleep 0.3
gpuq run -- bash -c "echo first >> $order" 2>/dev/null & first=$!
sleep 0.5
gpuq pause $first >/dev/null
gpuq run -- bash -c "echo second >> $order" 2>/dev/null &
sleep 0.5
check "status marks a paused job" bash -c "gpuq status | grep -q 'pid $first .*PAUSED'"
sleep 3
check "a paused job lets the jobs behind it go first" test "$(head -1 "$order")" = second
gpuq unpause $first >/dev/null
wait
check "an unpaused job runs" test "$(tail -1 "$order")" = first

setup 20000 20000
gpuq run -- bash -c 'echo "$CUDA_VISIBLE_DEVICES" > '"$GPUQ_DIR/assigned" 2>/dev/null & job=$!
sleep 0.5
check "assign rejects a card that doesn't exist" bash -c "! gpuq assign $job 7 2>/dev/null"
gpuq assign $job 1 >/dev/null
check "status shows the assignment" bash -c "gpuq status | grep -q 'pid $job .*assigned GPU 1'"
gpuq run -- bash -c 'echo "$CUDA_VISIBLE_DEVICES" > '"$GPUQ_DIR/other" 2>/dev/null & other=$!
sleep 0.5
sed -i 's/^1,GPU-1,NVIDIA Test,20000/1,GPU-1,NVIDIA Test,0/' "$FAKE_GPUS"
wait $job
check "an assigned job leases its card once it is free" test "$(cat "$GPUQ_DIR/assigned")" = 1
sleep 1
check "other jobs keep off an assigned card meanwhile" test ! -e "$GPUQ_DIR/other"
kill $other 2>/dev/null; wait $other 2>/dev/null

setup 0
gpuq pause >/dev/null
gpuq run -- bash -c 'echo "$CUDA_VISIBLE_DEVICES" > '"$GPUQ_DIR/assigned" 2>/dev/null & job=$!
sleep 0.5
check "assign on a paused queue wants a decision" bash -c "! gpuq assign $job 0 </dev/null 2>/dev/null"
gpuq assign $job 0 --override-pause >/dev/null
wait $job
check "--override-pause leases despite the pause" test "$(cat "$GPUQ_DIR/assigned")" = 0
gpuq unpause >/dev/null

setup 0
order="$GPUQ_DIR/order"
gpuq run -- sleep 2 2>/dev/null &
sleep 0.3
gpuq run -- bash -c "echo normal >> $order" 2>/dev/null & frozen=$!
sleep 0.3
kill -STOP $frozen
gpuq run --low -- bash -c "echo low >> $order" 2>/dev/null & low=$!
sleep 0.5
check "a frozen waiter is not listed" bash -c "! gpuq status | grep -q 'pid $frozen '"
wait $low
check "a frozen waiter doesn't hold back low jobs" test "$(head -1 "$order")" = low
kill -CONT $frozen; wait $frozen

setup 0
gpuq run -- sleep 2 2>/dev/null &
sleep 0.3
start=$(date +%s)
GPUQ_POLL_SECONDS=60 leased >/dev/null
check "a waiting job notices a freed card within seconds, not a full poll" test $(( $(date +%s) - start )) -le 6
wait

setup 0 0
check "cap prints the new caps" bash -c 'gpuq cap --total 1 | grep -q "caps now: total=1"'

setup 0
# An empty PATH: no nvidia-smi anywhere (it may live in /usr/bin on a real GPU box).
check "without nvidia-smi, gpuq says so instead of waiting" bash -c 'out=$(PATH=/nonexistent /bin/bash "'"$ROOT"'"/bin/gpuq run -- true 2>&1); [ $? -ne 0 ] && grep -q "nvidia-smi isn.t on PATH" <<< "$out"'
check "an unknown option is named" bash -c 'gpuq run --frobnicate -- true 2>&1 | grep -q "unknown option --frobnicate"'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
