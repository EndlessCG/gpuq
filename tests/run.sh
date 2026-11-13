#!/usr/bin/env bash
# gpuq's tests: the real gpuq and qtop against a fake nvidia-smi (tests/bin), no GPU needed.
# Run: tests/run.sh
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
export PATH="$ROOT/tests/bin:$ROOT/bin:$PATH"
export GPUQ_POLL_SECONDS=1
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
gpuq cap --exclude "0 1"
check "excluded cards are never leased" test "$(leased)" = 2
check "cap shows the exclusion" bash -c 'gpuq cap | grep -q "excluded=0 1"'
gpuq cap --exclude ""
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
gpuq cap --total 1
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

setup 0
# An empty PATH: no nvidia-smi anywhere (it may live in /usr/bin on a real GPU box).
check "without nvidia-smi, gpuq says so instead of waiting" bash -c 'out=$(PATH=/nonexistent /bin/bash "'"$ROOT"'"/bin/gpuq run -- true 2>&1); [ $? -ne 0 ] && grep -q "nvidia-smi isn.t on PATH" <<< "$out"'
check "an unknown option is named" bash -c 'gpuq run --frobnicate -- true 2>&1 | grep -q "unknown option --frobnicate"'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
