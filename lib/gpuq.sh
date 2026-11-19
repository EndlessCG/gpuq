# gpuq: a GPU lease queue for one user's jobs on a shared machine. Source it, or use bin/gpuq.
#
# State lives in $GPUQ_DIR (default ~/.gpuq), as plain files:
#   gpu_reservations/gpuN   the PID that holds card N; the lease lasts while that PID lives
#   gpu_waiting/PID         a job waiting for cards, holding its class (normal / low)
#   gpu_need/PID            how many cards it waits for (read by `gpuq status`)
#   gpu_priority            PIDs on the priority list, in order
#   gpu_meta/PID            a job's note and ETA (written by `gpuq run/acquire/note`)
#   gpu_held/PID            a waiting job paused by `gpuq pause PID`: it keeps its place, leases nothing
#   gpu_assign/PID          cards a waiting job must use (`gpuq assign`); 2nd line `override-pause`
#                           lets it lease while the whole queue is paused
#   gpu_paused              the whole queue is paused (`gpuq pause`): nothing new is leased
#   gpu_cap                 most cards your jobs may hold at once (default: every card)
#   gpu_lease_cap           most cards leased through gpuq at once (default: no extra limit)
#   gpu_exclude             cards never leased, by index ("3") or UUID ("GPU-8f1c..."); a UUID
#                           follows the card if it moves to another slot (default: none)
#   gpu_launch.lock         flock(1) lock every change to the queue takes
#
# Tunables (environment): GPUQ_FREE_MIB (a card counts as free below this much used memory,
# default 5000), GPUQ_CHECK_SECONDS (how often a waiting job checks whether anything changed,
# default 5), GPUQ_POLL_SECONDS (the longest it goes without a full retry, default 30),
# GPUQ_CANDIDATES (only consider these cards, e.g. "0 1"), GPUQ_CLASS (normal / low).
# (The older names GPU_POLL_SECONDS, GPU_CANDIDATES and GPU_PRIORITY_CLASS still work.)
#
# A card is free when no process of yours runs on it, no live lease holds it, it isn't
# excluded, and it uses less than GPUQ_FREE_MIB (so other users' jobs are skipped too).
PIDS="${GPUQ_DIR:-$HOME/.gpuq}"
mkdir -p "$PIDS/gpu_reservations" "$PIDS/gpu_waiting" "$PIDS/gpu_need" "$PIDS/gpu_meta" \
  "$PIDS/gpu_held" "$PIDS/gpu_assign"
GPUQ_UID="$(id -u)"
: "${GPUQ_POLL_SECONDS:=${GPU_POLL_SECONDS:-30}}"
: "${GPUQ_CHECK_SECONDS:=5}"
: "${GPUQ_CANDIDATES:=${GPU_CANDIDATES:-}}"
: "${GPUQ_CLASS:=${GPU_PRIORITY_CLASS:-normal}}"

# Is PID $1 alive? Through /proc, which (unlike a signal test) also sees other users' processes, so a
# queue shared by several users never mistakes someone else's job for a dead one.
gpu_alive() { [ -n "$1" ] && [ -d "/proc/$1" ]; }

# Is PID $1 frozen (SIGSTOP / ctrl-Z, ps state T)? A frozen waiter never polls, so the queue treats it
# as absent: it is not the priority head, it doesn't hold low jobs back, its assigned cards are not kept.
gpu_stopped() { [[ $(ps -o stat= -p "$1" 2>/dev/null) == T* ]]; }

# Forget what dead jobs left behind: leases, waiting entries, notes, pause and assign marks. Under the lock.
gpu_sweep() {
  local f p
  for f in "$PIDS"/gpu_reservations/gpu* "$PIDS"/gpu_waiting/* "$PIDS"/gpu_need/* "$PIDS"/gpu_meta/* \
           "$PIDS"/gpu_held/* "$PIDS"/gpu_assign/*; do
    [ -f "$f" ] || continue
    case "$f" in */gpu_reservations/*) p=$(cat "$f") ;; *) p=$(basename "$f") ;; esac
    gpu_alive "$p" || rm -f "$f"
  done
}

gpu_free_mib() { echo "${GPUQ_FREE_MIB:-5000}"; }
gpu_excluded() { grep -v '^[[:space:]]*#' "$PIDS/gpu_exclude" 2>/dev/null | tr ',' ' ' | xargs; }

# The excluded cards as indices, one per line: index entries as they are, UUID entries looked up.
gpu_excluded_indices() {
  local ex
  ex=$(gpu_excluded); [ -n "$ex" ] || return 0
  nvidia-smi --query-gpu=index,uuid --format=csv,noheader | awk -F', *' -v list="$ex" \
    'BEGIN{n=split(list,a," "); for(i=1;i<=n;i++) bad[a[i]]=1} ($1 in bad)||($2 in bad){print $1}'
}

# Cards to consider, in index order: GPUQ_CANDIDATES if set ("0 1" or "0,1"), else every card; minus the
# excluded ones (so --gpus can't pick an excluded card). With an owner PID ($1), cards assigned to another
# live waiting job (`gpuq assign`) are left out too.
gpu_candidates() {
  local all ex taken="" g
  all=$(nvidia-smi --query-gpu=index --format=csv,noheader | tr -d ' ')
  ex=$(gpu_excluded_indices)
  [ -n "${1:-}" ] && taken=$(gpu_assigned_elsewhere "$1")
  for g in $(tr ', ' '\n\n' <<< "${GPUQ_CANDIDATES:-$all}" | awk 'NF && !seen[$0]++'); do
    grep -qx "$g" <<< "$all" || continue
    grep -qx "$g" <<< "$ex" && continue
    grep -qx "$g" <<< "$taken" && continue
    echo "$g"
  done
}

# Most cards your jobs may hold at once: the gpu_cap file, else every card.
gpu_cap_value() {
  cat "$PIDS/gpu_cap" 2>/dev/null || nvidia-smi --query-gpu=index --format=csv,noheader | wc -l
}

gpu_mem_used() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "$1" | tr -d ' '; }
gpu_mem_all() { nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits; }  # "idx, MiB" lines

# Cards held by you: a process of yours runs on it, or a live lease holds it. A card counts once
# either way (counting the two separately double-counts every leased busy card).
gpu_held_indices() {
  local uuids apps mine r
  uuids=$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader)
  {
    apps=$(nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader | tr -d ' ')
    if [ -n "$apps" ]; then
      # One ps for every GPU process (not one per process): this runs under the lock on every attempt.
      mine=$(ps -o pid=,uid= -p "$(cut -d, -f2 <<< "$apps" | paste -sd,)" 2>/dev/null | awk -v me="$GPUQ_UID" '$2==me{print $1}')
      awk -F, -v mine="$mine" -v uuids="$uuids" 'BEGIN{n=split(mine,a,"\n"); for(i=1;i<=n;i++) me[a[i]]=1
        m=split(uuids,b,"\n"); for(i=1;i<=m;i++){split(b[i],f,", *"); idx[f[2]]=f[1]}}
        ($2 in me) && ($1 in idx){print idx[$1]}' <<< "$apps"
    fi
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
    # everyone listed after it. A paused job keeps its place but is skipped until unpaused; an
    # assigned job waits only for its own cards; a frozen one never polls. None of them holds the list up.
    [ -n "$p" ] && gpu_alive "$p" && [ -f "$PIDS/gpu_waiting/$p" ] && [ ! -f "$PIDS/gpu_held/$p" ] \
      && [ ! -f "$PIDS/gpu_assign/$p" ] && ! gpu_stopped "$p" && { echo "$p"; return 0; }
  done < "$PIDS/gpu_priority"
}

# Every waiting job registers in gpu_waiting/<pid> with its class (GPUQ_CLASS, default
# normal). gpu_need/<pid> is kept apart, because every file name in gpu_waiting/ is read as a PID.
gpu_waiting_register() {
  rm -f "$PIDS/gpu_held/$1" "$PIDS/gpu_assign/$1"   # marks left by an earlier process with this (reused) pid
  echo "$GPUQ_CLASS" > "$PIDS/gpu_waiting/$1"; echo "${2:-1}" > "$PIDS/gpu_need/$1"
}
gpu_waiting_clear() { rm -f "$PIDS/gpu_waiting/$1" "$PIDS/gpu_need/$1" "$PIDS/gpu_held/$1" "$PIDS/gpu_assign/$1"; }

# A low job doesn't lease while any other live normal job waits (a paused, assigned or frozen one
# doesn't count). Its class is read from its gpu_waiting file, not the environment, so `gpuq prio`
# can change it while it waits.
gpu_low_must_wait() {
  local w p
  [ "$(cat "$PIDS/gpu_waiting/$1" 2>/dev/null || echo "$GPUQ_CLASS")" = low ] || return 1
  for w in "$PIDS"/gpu_waiting/*; do
    [ -f "$w" ] || continue
    p=$(basename "$w"); [ "$p" = "$1" ] && continue
    gpu_alive "$p" || { rm -f "$w"; continue; }
    [ -f "$PIDS/gpu_held/$p" ] && continue
    [ -f "$PIDS/gpu_assign/$p" ] && continue
    gpu_stopped "$p" && continue
    [ "$(cat "$w")" = normal ] && return 0
  done
  return 1
}

# Card assignment (`gpuq assign PID GPUS`): gpu_assign/<pid> lists the cards (comma-separated) a waiting
# job must use. It leases exactly those as soon as enough are free, ahead of the queue order (priority
# list, low class), but within the caps and never on an excluded card. Other jobs leave them alone.
gpu_assigned_cards() { head -1 "$PIDS/gpu_assign/$1" 2>/dev/null | tr ', ' '\n\n' | grep -E '^[0-9]+$'; }
gpu_assigned_live() {  # is PID $1 a live, waiting, not frozen job with an assignment?
  [ -f "$PIDS/gpu_assign/$1" ] && gpu_alive "$1" && [ -f "$PIDS/gpu_waiting/$1" ] && ! gpu_stopped "$1"
}
gpu_assigned_elsewhere() {  # cards assigned to live waiting jobs other than PID $1
  local f p
  for f in "$PIDS"/gpu_assign/*; do
    [ -f "$f" ] || continue
    p=${f##*/}; [ "$p" = "$1" ] && continue
    gpu_assigned_live "$p" && gpu_assigned_cards "$p"
  done
}
# Under the lock: lease $2 of the cards assigned to PID $1 and print them comma-separated; fail
# (leasing nothing) if not enough of them are free or the caps don't allow it.
gpu_lease_assigned() {
  local owner=$1 need=$2 held mem ex g r found=() new=0
  held=$(gpu_held_indices); mem=$(gpu_mem_all); ex=$(gpu_excluded_indices)
  for g in $(gpu_assigned_cards "$owner"); do
    [ "${#found[@]}" -ge "$need" ] && break
    grep -qx "$g" <<< "$ex" && continue
    if [ "$(cat "$PIDS/gpu_reservations/gpu$g" 2>/dev/null)" = "$owner" ]; then found+=("$g"); continue; fi
    gpu_is_free "$g" "$held" "$mem" || continue
    found+=("$g"); new=$((new+1))
  done
  [ "${#found[@]}" -ge "$need" ] || return 1
  [ $(( $(grep -c . <<< "$held") + new )) -le "$(gpu_cap_value)" ] || return 1
  [ "$(gpu_lease_room)" -ge "$new" ] || return 1
  # Cards this owner collected earlier (e.g. as priority head) outside its assignment go back to the pool.
  for r in "$PIDS"/gpu_reservations/gpu*; do
    [ -f "$r" ] && [ "$(cat "$r")" = "$owner" ] || continue
    [[ " ${found[*]} " == *" ${r##*/gpu} "* ]] || rm -f "$r"
  done
  for g in "${found[@]}"; do echo "$owner" > "$PIDS/gpu_reservations/gpu$g"; done
  [ -f "$PIDS/gpu_priority" ] && sed -i "/^$owner\$/d" "$PIDS/gpu_priority"
  gpu_waiting_clear "$owner"
  (IFS=,; echo "${found[*]}")
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

# Is card $1 free to lease right now? $2: the held list, $3: the memory list (gpu_mem_all), both read
# once per attempt; reading them per card made one attempt take ~10 s under the lock on an 8-card box.
gpu_is_free() {
  local m
  grep -qx "$1" <<< "$2" && return 1
  m=$(awk -F', *' -v g="$1" '$1==g{print $2}' <<< "$3")
  [ -n "$m" ] && [ "$m" -lt "$(gpu_free_mib)" ]
}

# A cheap digest of everything that can let a waiting job lease: cards that look free, GPU processes,
# live leases, caps, exclusions, the priority list, pause and assign marks, live waiters. One
# nvidia-smi pair, no ps per process.
gpu_queue_fingerprint() {
  local w r
  { gpu_mem_all | awk -F', *' -v lim="$(gpu_free_mib)" '$2<lim{print "free " $1}'
    nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader
    # live leases only: a lease whose job has ended frees its card even before the card's memory drops
    for r in "$PIDS"/gpu_reservations/gpu*; do [ -f "$r" ] && gpu_alive "$(cat "$r")" && echo "lease ${r##*/}"; done
    grep -H . "$PIDS"/gpu_cap "$PIDS"/gpu_lease_cap "$PIDS"/gpu_exclude \
      "$PIDS"/gpu_priority "$PIDS"/gpu_paused "$PIDS"/gpu_held/* "$PIDS"/gpu_assign/* "$PIDS"/gpu_waiting/* 2>/dev/null
    for w in "$PIDS"/gpu_waiting/*; do [ -f "$w" ] && gpu_alive "${w##*/}" && echo "live ${w##*/}"; done
  } | cksum
}

# After a failed attempt: look every GPUQ_CHECK_SECONDS and return as soon as the queue differs from $1
# (the fingerprint taken when the attempt started), or after GPUQ_POLL_SECONDS in any case. A card that
# frees up is noticed within seconds instead of after a blind full poll interval.
gpu_wait_for_change() {
  local t=0 step=$GPUQ_CHECK_SECONDS max=$GPUQ_POLL_SECONDS
  [ "$step" -gt "$max" ] && step=$max
  while [ "$t" -lt "$max" ]; do
    sleep "$step"; t=$((t+step))
    [ "$(gpu_queue_fingerprint)" != "$1" ] && return 0
  done
}

# Reserve one free card for PID $1 and print it, waiting under the shared lock and caps.
gpu_acquire_one() { gpu_acquire_n "$1" 1; }

# Reserve $2 free cards for PID $1 and print them comma-separated. Returns 1 (leasing nothing)
# if PID $1 dies while it waits, so an abandoned wait never polls on forever.
gpu_acquire_n() {
  local owner=$1 need=$2 cap held mem heldn g found head r mine asg fp
  gpu_waiting_register "$owner" "$need"
  exec 8>"$PIDS/gpu_launch.lock"
  while true; do
    flock 8
    gpu_sweep
    if ! gpu_alive "$owner"; then flock -u 8; exec 8>&-; return 1; fi
    # Owner frozen (SIGSTOP / ctrl-Z): this loop runs in a child process and keeps going, but a card
    # leased now would sit idle under a job that can't start. Wait until it is resumed.
    if gpu_stopped "$owner"; then flock -u 8; sleep "$GPUQ_CHECK_SECONDS"; continue; fi
    # Queue paused (`gpuq pause`): lease nothing new; jobs keep their place and the cards they hold.
    # An assignment made with --override-pause lets that one job lease anyway.
    if [ -f "$PIDS/gpu_paused" ] && ! grep -qx override-pause "$PIDS/gpu_assign/$owner" 2>/dev/null; then
      flock -u 8; sleep "$GPUQ_CHECK_SECONDS"; continue
    fi
    # This job paused (`gpuq pause PID`): lease nothing for it until unpaused.
    if [ -f "$PIDS/gpu_held/$owner" ]; then flock -u 8; sleep "$GPUQ_CHECK_SECONDS"; continue; fi
    # Assigned to specific cards (`gpuq assign`): lease exactly those once free, ahead of the queue order.
    if [ -f "$PIDS/gpu_assign/$owner" ]; then
      if asg=$(gpu_lease_assigned "$owner" "$need"); then flock -u 8; exec 8>&-; echo "$asg"; return; fi
      flock -u 8; sleep "$GPUQ_CHECK_SECONDS"; continue
    fi
    fp=$(gpu_queue_fingerprint)
    head=$(gpu_priority_head); [ -n "$head" ] && [ "$head" = "$owner" ] && gpu_priority_reclaim "$owner"
    cap=$(gpu_cap_value); held=$(gpu_held_indices); mem=$(gpu_mem_all); heldn=$(grep -c . <<< "$held"); found=()
    if [ -n "$head" ] && [ "$head" = "$owner" ]; then
      # Priority head: keep cards already reserved for this owner and add each newly free one.
      mine=()
      for r in "$PIDS"/gpu_reservations/gpu*; do
        [ -f "$r" ] && [ "$(cat "$r")" = "$owner" ] && mine+=("$(basename "$r" | sed 's/^gpu//')")
      done
      for g in $(gpu_candidates "$owner"); do
        [ "${#mine[@]}" -ge "$need" ] && break
        [ "$heldn" -lt "$cap" ] || break
        [ "$(gpu_lease_room)" -ge 1 ] || break
        gpu_is_free "$g" "$held" "$mem" || continue
        echo "$owner" > "$PIDS/gpu_reservations/gpu$g"; mine+=("$g"); heldn=$((heldn+1)); held+=$'\n'"$g"
      done
      if [ "${#mine[@]}" -ge "$need" ]; then
        # Leased: leave the priority list so the next listed job (or first-to-fit) proceeds.
        sed -i "/^$owner\$/d" "$PIDS/gpu_priority"; gpu_waiting_clear "$owner"
        flock -u 8; exec 8>&-; (IFS=,; echo "${mine[*]:0:$need}"); return
      fi
      flock -u 8; gpu_wait_for_change "$fp"; continue
    fi
    if [ -n "$head" ]; then flock -u 8; gpu_wait_for_change "$fp"; continue; fi
    if [ $(( heldn + need )) -le "$cap" ] && [ "$(gpu_lease_room)" -ge "$need" ] && ! gpu_low_must_wait "$owner"; then
      for g in $(gpu_candidates "$owner"); do
        gpu_is_free "$g" "$held" "$mem" && found+=("$g")
        [ "${#found[@]}" -eq "$need" ] && break
      done
    fi
    if [ "${#found[@]}" -eq "$need" ]; then
      for g in "${found[@]}"; do echo "$owner" > "$PIDS/gpu_reservations/gpu$g"; done
      gpu_waiting_clear "$owner"; flock -u 8; exec 8>&-; (IFS=,; echo "${found[*]}"); return
    fi
    flock -u 8; gpu_wait_for_change "$fp"
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
