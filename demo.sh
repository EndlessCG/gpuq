#!/usr/bin/env bash
# See gpuq at work without any GPUs: 8 pretend cards (tests/bin/nvidia-smi), a few real gpuq jobs
# competing for them, and qtop showing it all. Everything lives in a temp folder and is cleaned up
# when you quit qtop (q). `./demo.sh --once` prints one snapshot instead.
cd "$(dirname "$0")" || exit 1
ROOT=$PWD
export PATH="$ROOT/tests/bin:$ROOT/bin:$PATH"
export GPUQ_DIR; GPUQ_DIR=$(mktemp -d)
export FAKE_GPUS="$GPUQ_DIR/gpus.csv" FAKE_APPS="$GPUQ_DIR/apps.csv" GPUQ_POLL_SECONDS=1
export GPUQ_HOST_LABEL="demo · 8 pretend H100s"
# Each job runs in its own process group (setsid), so quitting stops the job and its gpuq wait,
# not just the wrapper.
groups=()
trap 'for g in "${groups[@]}"; do kill -- -"$g" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$GPUQ_DIR"' EXIT

cards() {  # rewrite the pretend cards: leased ones look busy, card 5 belongs to someone else
  local i mem util
  : > "$FAKE_GPUS"
  for i in 0 1 2 3 4 5 6 7; do
    mem=600 util=0
    [ -f "$GPUQ_DIR/gpu_reservations/gpu$i" ] && mem=$((52000 + i * 1700)) util=$((88 + i))
    [ "$i" = 5 ] && mem=31000 util=97
    echo "$i,GPU-$i,NVIDIA H100 80GB HBM3,$mem,81559,$util,$((38 + util / 3)),$((90 + util * 5)),700" >> "$FAKE_GPUS"
  done
  echo "GPU-5,1,30800" > "$FAKE_APPS"   # pid 1 is root's: "another user's job"
}
job() { setsid gpuq run "$@" 2>/dev/null & groups+=($!); sleep 0.4; cards; }

cards
job -n 4 --note "GRPO 7B, length penalty" --eta 3h -- sleep 3600
job -n 2 --note "MMLU eval sweep" --eta 40m -- sleep 3600
job -n 2 --note "pretrain 1.3B" --eta 30h -- sleep 3600      # waits: only card 7 is free
job --low --note "tokenize web shard 7" --eta 20m -- sleep 3600  # waits behind every normal job
job --high --note "urgent: rerun the failed eval" --eta 15m -- sleep 3600  # jumps the queue
sleep 1.5; cards

if [ "${1:-}" = --once ]; then qtop --once; else qtop; fi
