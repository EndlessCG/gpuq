# gpuq: a GPU lease queue for one user's jobs on a shared machine. Source it, or use bin/gpuq.
#
# State lives in $GPUQ_DIR (default ~/.gpuq), as plain files:
#   gpu_reservations/gpuN   the PID that holds card N; the lease lasts while that PID lives
#   gpu_waiting/PID         a job waiting for cards, holding its class (normal / low)
#   gpu_need/PID            how many cards it waits for (read by `gpuq status`)
#   gpu_priority            PIDs on the priority list, in order
#   gpu_meta/PID            a job's note and ETA (written by `gpuq run/acquire/note`)
#   gpu_cap                 most cards your jobs may hold at once (default: every card)
#   gpu_lease_cap           most cards leased through gpuq at once (default: no extra limit)
#   gpu_exclude             cards never leased, e.g. "3" for a faulty one (default: none)
#   gpu_launch.lock         flock(1) lock every change to the queue takes
#
# Tunables (environment): GPUQ_FREE_MIB (a card counts as free below this much used memory,
# default 5000), GPUQ_POLL_SECONDS (how often a waiting job looks again, default 30),
# GPUQ_CANDIDATES (only consider these cards, e.g. "0 1"), GPUQ_CLASS (normal / low).
# (The older names GPU_POLL_SECONDS, GPU_CANDIDATES and GPU_PRIORITY_CLASS still work.)
#
# A card is free when no process of yours runs on it, no live lease holds it, it isn't
# excluded, and it uses less than GPUQ_FREE_MIB (so other users' jobs are skipped too).
PIDS="${GPUQ_DIR:-$HOME/.gpuq}"
mkdir -p "$PIDS/gpu_reservations" "$PIDS/gpu_waiting" "$PIDS/gpu_need" "$PIDS/gpu_meta"
GPUQ_USER="$(id -un)"
: "${GPUQ_POLL_SECONDS:=${GPU_POLL_SECONDS:-30}}"
: "${GPUQ_CANDIDATES:=${GPU_CANDIDATES:-}}"
: "${GPUQ_CLASS:=${GPU_PRIORITY_CLASS:-normal}}"

# Is PID $1 alive? Through /proc, which (unlike a signal test) also sees other users' processes, so a
# queue shared by several users never mistakes someone else's job for a dead one.
gpu_alive() { [ -n "$1" ] && [ -d "/proc/$1" ]; }

# Forget what dead jobs left behind: leases, waiting entries, notes. Called under the lock.
gpu_sweep() {
  local f p
  for f in "$PIDS"/gpu_reservations/gpu* "$PIDS"/gpu_waiting/* "$PIDS"/gpu_need/* "$PIDS"/gpu_meta/*; do
    [ -f "$f" ] || continue
    case "$f" in */gpu_reservations/*) p=$(cat "$f") ;; *) p=$(basename "$f") ;; esac
    gpu_alive "$p" || rm -f "$f"
  done
}

gpu_free_mib() { echo "${GPUQ_FREE_MIB:-5000}"; }
gpu_excluded() { cat "$PIDS/gpu_exclude" 2>/dev/null; }

# Cards to consider, in index order: GPU_CANDIDATES if set, else every card minus the excluded.
gpu_candidates() {
  local ex g
  ex=" $(gpu_excluded | tr ',\n' '  ') "
  for g in ${GPUQ_CANDIDATES:-$(nvidia-smi --query-gpu=index --format=csv,noheader)}; do
    [[ $ex == *" $g "* ]] || echo "$g"
  done
}

# Most cards your jobs may hold at once: the gpu_cap file, else every card.
gpu_cap_value() {
  cat "$PIDS/gpu_cap" 2>/dev/null || nvidia-smi --query-gpu=index --format=csv,noheader | wc -l
}

gpu_mem_used() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "$1" | tr -d ' '; }

# Cards held by you: a process of yours runs on it, or a live lease holds it. A card counts once
# either way (counting the two separately double-counts every leased busy card).
gpu_held_indices() {
  local uuids
  uuids=$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader)  # once, not once per process
  {
    nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader | while IFS=, read -r u p; do
      [ "$(ps -o user= -p "${p// /}" 2>/dev/null)" = "$GPUQ_USER" ] || continue
      awk -F', ' -v u="${u// /}" '$2==u{print $1}' <<< "$uuids"
    done
    for r in "$PIDS"/gpu_reservations/gpu*; do
      [ -f "$r" ] && gpu_alive "$(cat "$r")" && basename "$r" | sed 's/^gpu//'
    done
  } | grep -v '^$' | sort -u
}

# Cards leased through gpuq (live lease PIDs). Your own processes started outside gpuq don't count.
gpu_reserved_count() {
  local r n=0
  for r in "$PIDS"/gpu_reservations/gpu*; do
    [ -f "$r" ] && gpu_alive "$(cat "$r")" && n=$((n+1))
  done
  echo "$n"
}

# The priority list: while any listed PID is alive and waiting, only the FIRST such one may lease.
# It takes free cards one at a time as they free up (so single-card jobs can't starve a multi-card
# job), and every other job waits. An empty or absent list means plain first-to-fit.
gpu_priority_head() {
  local p
  [ -f "$PIDS/gpu_priority" ] || return 0
  while read -r p; do
    # Only a PID still waiting can be the head: one that already holds its lease would block
    # everyone listed after it.
    [ -n "$p" ] && gpu_alive "$p" && [ -f "$PIDS/gpu_waiting/$p" ] && { echo "$p"; return 0; }
  done < "$PIDS/gpu_priority"
}

# Every waiting job registers in gpu_waiting/<pid> with its class (GPUQ_CLASS, default
# normal). gpu_need/<pid> is kept apart, because every file name in gpu_waiting/ is read as a PID.
gpu_waiting_register() {
  echo "$GPUQ_CLASS" > "$PIDS/gpu_waiting/$1"; echo "${2:-1}" > "$PIDS/gpu_need/$1"
}
gpu_waiting_clear() { rm -f "$PIDS/gpu_waiting/$1" "$PIDS/gpu_need/$1"; }

# A low job doesn't lease while any other live normal job waits. Its class is read from its
# gpu_waiting file, not the environment, so `gpuq prio` can change it while it waits.
gpu_low_must_wait() {
  local w p
  [ "$(cat "$PIDS/gpu_waiting/$1" 2>/dev/null || echo "$GPUQ_CLASS")" = low ] || return 1
  for w in "$PIDS"/gpu_waiting/*; do
    [ -f "$w" ] || continue
    p=$(basename "$w"); [ "$p" = "$1" ] && continue
    gpu_alive "$p" || { rm -f "$w"; continue; }
    [ "$(cat "$w")" = normal ] && return 0
  done
  return 1
}

# The priority head may take back a card that a job lower on the list reserved while it was the
# head and still holds idle (it's still waiting and nothing runs on the card). Without this a
# newly prepended head starves while a multi-card job below sits on a partial, unused lease.
gpu_priority_reclaim() {
  local head=$1 r o g
  for r in "$PIDS"/gpu_reservations/gpu*; do
    [ -f "$r" ] || continue
    o=$(cat "$r"); [ "$o" = "$head" ] && continue
    grep -qx "$o" "$PIDS/gpu_priority" 2>/dev/null || continue
    [ -f "$PIDS/gpu_waiting/$o" ] || continue
    g=$(basename "$r" | sed 's/^gpu//')
    [ "$(gpu_mem_used "$g")" -lt "$(gpu_free_mib)" ] || continue
    rm -f "$r"
  done
}

# Room left under gpu_lease_cap (no file: no extra limit).
gpu_lease_room() {
  [ -f "$PIDS/gpu_lease_cap" ] || { echo 999; return; }
  echo $(( $(cat "$PIDS/gpu_lease_cap") - $(gpu_reserved_count) ))
}

# Is card $1 free to lease right now? ($2: the held list, so nvidia-smi runs once per pass.)
gpu_is_free() {
  grep -qx "$1" <<< "$2" && return 1
  [ "$(gpu_mem_used "$1")" -lt "$(gpu_free_mib)" ]
}

# Reserve one free card for PID $1 and print it, waiting under the shared lock and caps.
gpu_acquire_one() { gpu_acquire_n "$1" 1; }

# Reserve $2 free cards for PID $1 and print them comma-separated. Returns 1 (leasing nothing)
# if PID $1 dies while it waits, so an abandoned wait never polls on forever.
gpu_acquire_n() {
  local owner=$1 need=$2 cap held heldn g found head r mine
  gpu_waiting_register "$owner" "$need"
  exec 8>"$PIDS/gpu_launch.lock"
  while true; do
    flock 8
    gpu_sweep
    if ! gpu_alive "$owner"; then flock -u 8; exec 8>&-; return 1; fi
    head=$(gpu_priority_head); [ -n "$head" ] && [ "$head" = "$owner" ] && gpu_priority_reclaim "$owner"
    cap=$(gpu_cap_value); held=$(gpu_held_indices); heldn=$(grep -c . <<< "$held"); found=()
    if [ -n "$head" ] && [ "$head" = "$owner" ]; then
      # Priority head: keep cards already reserved for this owner and add each newly free one.
      mine=()
      for r in "$PIDS"/gpu_reservations/gpu*; do
        [ -f "$r" ] && [ "$(cat "$r")" = "$owner" ] && mine+=("$(basename "$r" | sed 's/^gpu//')")
      done
      for g in $(gpu_candidates); do
        [ "${#mine[@]}" -ge "$need" ] && break
        [ "$heldn" -lt "$cap" ] || break
        [ "$(gpu_lease_room)" -ge 1 ] || break
        gpu_is_free "$g" "$held" || continue
        echo "$owner" > "$PIDS/gpu_reservations/gpu$g"; mine+=("$g"); heldn=$((heldn+1)); held+=$'\n'"$g"
      done
      if [ "${#mine[@]}" -ge "$need" ]; then
        # Leased: leave the priority list so the next listed job (or first-to-fit) proceeds.
        sed -i "/^$owner\$/d" "$PIDS/gpu_priority"; gpu_waiting_clear "$owner"
        flock -u 8; exec 8>&-; (IFS=,; echo "${mine[*]:0:$need}"); return
      fi
      flock -u 8; sleep 5; continue
    fi
    if [ -n "$head" ]; then flock -u 8; sleep "$GPUQ_POLL_SECONDS"; continue; fi
    if [ $(( heldn + need )) -le "$cap" ] && [ "$(gpu_lease_room)" -ge "$need" ] && ! gpu_low_must_wait "$owner"; then
      for g in $(gpu_candidates); do
        gpu_is_free "$g" "$held" && found+=("$g")
        [ "${#found[@]}" -eq "$need" ] && break
      done
    fi
    if [ "${#found[@]}" -eq "$need" ]; then
      for g in "${found[@]}"; do echo "$owner" > "$PIDS/gpu_reservations/gpu$g"; done
      gpu_waiting_clear "$owner"; flock -u 8; exec 8>&-; (IFS=,; echo "${found[*]}"); return
    fi
    flock -u 8; sleep "$GPUQ_POLL_SECONDS"
  done
}

# Release every card reserved for PID $1 and drop it from the waiting jobs and the priority list.
# (A dead owner's leases are ignored by the queue anyway; this frees them at once.)
gpu_release() {
  local owner=$1 r
  exec 8>"$PIDS/gpu_launch.lock"; flock 8
  for r in "$PIDS"/gpu_reservations/gpu*; do
    [ -f "$r" ] && [ "$(cat "$r")" = "$owner" ] && rm -f "$r"
  done
  gpu_waiting_clear "$owner"; rm -f "$PIDS/gpu_meta/$owner"
  [ -f "$PIDS/gpu_priority" ] && sed -i "/^$owner\$/d" "$PIDS/gpu_priority"
  flock -u 8; exec 8>&-
}
