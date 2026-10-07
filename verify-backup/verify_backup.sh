#!/bin/bash
# verify_backup.sh — check that every file in one or more source folders was copied to its destination(s).
#
# Usage: verify_backup.sh [options] <command> [fast|full]
#
# Commands (run them one after the other; with -d they run in the background and survive SSH logout):
#   size                 quick check: presence + file size only (seconds)
#   hash-src [fast|full] 1) hash every source file
#   hash-dst [fast|full] 2) hash every destination file
#   compare  [fast|full] 3) compare source and destination hashes, write a report
#   status               show what is running, progress, and which hashes are done
#   stop                 stop the running step; running it again resumes where it left off
#
# Options:
#   -d, --detach         run the command in the background (log in <workdir>/<command>.log)
#   -c, --config FILE    mapping file (default: verify_backup.conf next to this script)
#   -w, --workdir DIR    where hashes and reports are stored (default: verify_work/ next to this script)
#   -h, --help           show this help
#
# Modes:
#   fast = hash of the first and last CHUNK_MB of each file (default)
#   full = hash of the whole file
#
# Environment: HASH_CMD (default md5sum), CHUNK_MB (default 4), PARALLEL (readers per device, default 1)

set -u
export LC_ALL=C

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SELF")"

export HASH="${HASH_CMD:-md5sum}"
CHUNK_MB="${CHUNK_MB:-4}"
export CHUNK=$((CHUNK_MB * 1024 * 1024))
PARALLEL="${PARALLEL:-1}"

die()   { echo "ERROR: $*" >&2; exit 2; }
usage() { sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2; }
alive() { kill -0 "$1" 2>/dev/null || [ -d "/proc/$1" ]; }
check_mode() { case "$1" in fast|full) ;; *) die "invalid mode: $1 (use fast or full)" ;; esac; }

# Label used in file names, so hashes made with different settings are never mixed up
tag_for() {
  local algo=${HASH%sum}
  if [ "$1" = fast ]; then echo "fast${CHUNK_MB}M-$algo"; else echo "full-$algo"; fi
}

# ---------------------------------------------------------------- options
CONF="$SCRIPT_DIR/verify_backup.conf"
WORK="$SCRIPT_DIR/verify_work"
DETACH=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--detach)  DETACH=1; shift ;;
    -c|--config)  [ $# -ge 2 ] || die "$1 needs a file";      CONF=$2; shift 2 ;;
    -w|--workdir) [ $# -ge 2 ] || die "$1 needs a directory"; WORK=$2; shift 2 ;;
    -h|--help)    usage ;;
    -*)           die "unknown option: $1" ;;
    *)            break ;;
  esac
done
[ $# -ge 1 ] || usage

mkdir -p "$WORK" || exit 2
WORK="$(cd "$WORK" && pwd)"
[ -e "$CONF" ] && CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
command -v "$HASH" >/dev/null 2>&1 || die "hash command not found: $HASH"

# ---------------------------------------------------------------- configuration
# One mapping per line:   NAME | SOURCE | DEST1 [| DEST2 ...]
# A source file counts as copied if it exists, with the same relative path, in at least one destination.
MAPPINGS=()
load_config() {
  local line
  [ -f "$CONF" ] || die "config file not found: $CONF (copy verify_backup.conf.example to verify_backup.conf)"
  while IFS= read -r line; do
    case "$line" in BAD:*) die "invalid line in $CONF — ${line#BAD:}" ;; esac
    MAPPINGS+=("$line")
  done < <(awk -F'|' '
    /^[[:space:]]*(#|$)/ { next }
    {
      out = ""; n = 0
      for (i = 1; i <= NF; i++) {
        f = $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
        if (f == "") continue
        out = out (n++ ? "|" : "") f
      }
      split(out, a, "|")
      if (n < 3)                    print "BAD:line " NR ": expected NAME | SOURCE | DEST [| DEST ...]"
      else if (a[1] !~ /^[A-Za-z0-9._-]+$/) print "BAD:line " NR ": NAME may only contain letters, digits, . _ -"
      else                          print out
    }' "$CONF")
  [ ${#MAPPINGS[@]} -gt 0 ] || die "no mappings in $CONF"

  local job d i missing=0
  local -a f
  for job in "${MAPPINGS[@]}"; do
    IFS='|' read -r -a f <<< "$job"
    for ((i = 1; i < ${#f[@]}; i++)); do
      d=${f[$i]}
      [ -d "$d" ] || { echo "ERROR: directory not found: $d (mapping ${f[0]})" >&2; missing=1; }
    done
  done
  [ "$missing" = 0 ] || exit 2
}

# ---------------------------------------------------------------- background launch
if [ "$DETACH" = 1 ]; then
  case "$1" in size|hash-src|hash-dst|compare) ;; *) die "only size, hash-src, hash-dst and compare can run with -d" ;; esac
  [ "$1" = compare ] || load_config   # fail now, not in the background
  pf="$WORK/$1.pid"
  [ -e "$pf" ] && alive "$(cat "$pf")" && die "$1 is already running (PID $(cat "$pf"))"
  logf="$WORK/$1.log"
  if command -v setsid >/dev/null 2>&1; then
    VERIFY_BG=1 nohup setsid bash "$SELF" -c "$CONF" -w "$WORK" "$@" > "$logf" 2>&1 < /dev/null &
  else
    VERIFY_BG=1 nohup bash "$SELF" -c "$CONF" -w "$WORK" "$@" > "$logf" 2>&1 < /dev/null &
  fi
  echo "Started in background: $* (PID $!)"
  echo "Log:    tail -f $logf"
  echo "Status: $SELF -w $WORK status"
  echo "You can close the SSH session now."
  exit 0
fi

# Mark the command as running; on stop, also kill the child processes
pids=()
lock() {
  local f="$WORK/$1.pid"
  [ -e "$f" ] && [ "$(cat "$f")" != $$ ] && alive "$(cat "$f")" && die "$1 is already running (PID $(cat "$f"))"
  echo $$ > "$f"
  [ -z "${VERIFY_BG:-}" ] && exec > >(tee "$WORK/$1.log") 2>&1   # foreground: also write the log
  trap "rm -f '$f'" EXIT
  trap 'kill ${pids[@]+"${pids[@]}"} 2>/dev/null; echo "Stopped: $(date)"; exit 143' TERM INT
}

# List files under $1 as "relative_path<TAB>bytes", skipping Synology/macOS/Windows metadata
list_files() {
  ( cd "$1" && find . \( -name '@eaDir' -o -name '#recycle' \) -prune -o \
      -type f ! -name '.DS_Store' ! -name 'Thumbs.db' -print0 \
    | xargs -0 -r stat -c $'%n\t%s' ) | sed 's|^\./||' | sort
}

# Every file of one side (src|dst) as "name<TAB>root<TAB>relative_path<TAB>bytes"
list_side() {
  local side=$1 job d i
  local -a f
  for job in "${MAPPINGS[@]}"; do
    IFS='|' read -r -a f <<< "$job"
    for ((i = 1; i < ${#f[@]}; i++)); do
      [ "$side" = src ] && [ "$i" -gt 1 ] && break
      [ "$side" = dst ] && [ "$i" -eq 1 ] && continue
      d=${f[$i]}
      list_files "$d" | awk -F'\t' -v OFS='\t' -v job="${f[0]}" -v root="$d" '{ print job, root, $1, $2 }'
    done
  done
}

# Mount point of a directory, as a file-name-safe label (one reader group per physical device)
device_label() {
  local m
  m=$(df -P "$1" 2>/dev/null | awk 'NR == 2 { print $NF }')
  m=$(printf '%s' "${m:-unknown}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//')
  echo "${m:-root}"
}

hash_one() {
  set -o pipefail
  local h
  if [ "$MODE" = fast ]; then
    h=$( { head -c "$CHUNK" -- "$1" && tail -c "$CHUNK" -- "$1"; } | $HASH ) || h="ERROR"
  else
    h=$( $HASH < "$1" ) || h="ERROR"
  fi
  printf '%s\t%s\n' "${h%% *}" "$1"
}
export -f hash_one

# ---------------------------------------------------------------- hash-src / hash-dst
cmd_hash() {
  local side=$1 mode=$2 tag run lst dev t line root nerr
  check_mode "$mode"
  load_config
  export MODE=$mode
  tag=$(tag_for "$mode")
  lock "hash-$side"
  echo "== hash-$side ($tag) — started $(date)"
  echo "Listing files..."
  list_side "$side" > "$WORK/$side.list.tsv"

  # Group files by physical device so different disks are read at the same time,
  # skipping files already hashed by a previous run (resume after stop or interruption)
  cut -f2 "$WORK/$side.list.tsv" | sort -u | while IFS= read -r root; do
    printf '%s\t%s\n' "$root" "$(device_label "$root")"
  done > "$WORK/$side.devices.tsv"
  run=$(date +%Y%m%d_%H%M%S)
  rm -f "$WORK"/todo."$side".*.lst
  cat "$WORK"/raw."$side"."$tag".*.tsv > "$WORK/done.$side.tmp" 2>/dev/null
  awk -F'\t' -v out="$WORK/todo.$side" '
    FILENAME == ARGV[1] { dev[$1] = $2; next }
    FILENAME == ARGV[2] { if ($1 != "ERROR" && $2 != "") done[$2] = 1; next }
    { p = $2 "/" $3; if (p in done) { skip++; next }
      n++; bytes += $4; print p > (out "." dev[$2] ".lst") }
    END { printf "To hash: %d files (%.1f GB)", n, bytes / 1e9
          if (skip) printf " — already hashed by a previous run: %d", skip
          print "" }' "$WORK/$side.devices.tsv" "$WORK/done.$side.tmp" "$WORK/$side.list.tsv"

  for lst in "$WORK"/todo."$side".*.lst; do
    [ -e "$lst" ] || continue
    dev=${lst##*/todo."$side".}; dev=${dev%.lst}
    echo "  $dev: $(wc -l < "$lst" | tr -d ' ') files (parallel readers: $PARALLEL)"
    tr '\n' '\0' < "$lst" | xargs -0 -n 1 -P "$PARALLEL" bash -c 'hash_one "$1"' _ \
      > "$WORK/raw.$side.$tag.$dev.$run.tsv" &
    pids+=($!)
  done

  t=0
  while :; do
    running=0
    for p in ${pids[@]+"${pids[@]}"}; do kill -0 "$p" 2>/dev/null && running=1; done
    [ "$running" = 0 ] && break
    sleep 2; t=$((t + 2))
    [ $((t % 60)) -eq 0 ] || continue   # progress once a minute
    line="  $(date +%H:%M:%S)"
    for lst in "$WORK"/todo."$side".*.lst; do
      dev=${lst##*/todo."$side".}; dev=${dev%.lst}
      line="$line   $dev $(wc -l < "$WORK/raw.$side.$tag.$dev.$run.tsv" | tr -d ' ')/$(wc -l < "$lst" | tr -d ' ')"
    done
    echo "$line"
  done
  wait

  # Final manifest: name, root, relative path, bytes, hash
  cat "$WORK"/raw."$side"."$tag".*.tsv > "$WORK/done.$side.tmp" 2>/dev/null
  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { h[$2] = $1; next }
    { p = $2 "/" $3; print $0, ((p in h) ? h[p] : "ERROR") }
  ' "$WORK/done.$side.tmp" "$WORK/$side.list.tsv" > "$WORK/$side.hash.$tag.tsv"
  rm -f "$WORK/done.$side.tmp" "$WORK"/todo."$side".*.lst

  nerr=$(awk -F'\t' '$5 == "ERROR"' "$WORK/$side.hash.$tag.tsv" | wc -l | tr -d ' ')
  echo "== hash-$side ($tag) finished $(date) — $(wc -l < "$WORK/$side.hash.$tag.tsv" | tr -d ' ') files, read errors: $nerr (${SECONDS}s)"
  echo "Manifest: $WORK/$side.hash.$tag.tsv"
}

# ---------------------------------------------------------------- compare
# $1 = source manifest, $2 = destination manifest, $3 = label (size or hash tag)
do_compare() {
  local s=$1 d=$2 tag=$3 out problems
  out="$WORK/report_${tag}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$out"
  {
    echo "Comparison ($tag) — $(date)"
    echo "Source:      $s"
    echo "Destination: $d"
    echo ""
    awk -F'\t' -v OFS='\t' -v out="$out" -v mode="$tag" '
      FILENAME == ARGV[1] { k = $1 SUBSEP $3; n = ++cnt[k]; drt[k, n] = $2; dsz[k, n] = $4; dh[k, n] = $5; next }
      {
        job = $1; k = $1 SUBSEP $3; nsrc[job]++; bytes[job] += $4; seen[k] = 1
        if (!(k in cnt)) { print $3, $4 > (out "/" job ".MISSING.txt"); miss[job]++; next }
        good = 0; samesize = 0; err = 0; where = ""
        for (i = 1; i <= cnt[k]; i++) {
          st = "OK"
          if (dsz[k, i] != $4) st = "size " dsz[k, i]
          else {
            samesize = 1
            if (mode != "size") {
              if ($5 == "ERROR" || dh[k, i] == "ERROR") { st = "READ_ERROR"; err = 1 }
              else if ($5 != dh[k, i]) st = "HASH_MISMATCH"
            }
          }
          if (st == "OK") good = 1
          where = where (i > 1 ? " | " : "") drt[k, i] " [" st "]"
        }
        if (good) ok[job]++
        else if (err)      { print $3, where > (out "/" job ".READ_ERRORS.txt"); nerr[job]++ }
        else if (samesize) { print $3, where > (out "/" job ".HASH_MISMATCH.txt"); nbad[job]++ }
        else               { print $3, "source " $4, where > (out "/" job ".SIZE_MISMATCH.txt"); nsize[job]++ }
        if (cnt[k] > 1)    { print $3, where > (out "/" job ".MULTIPLE_COPIES.txt"); ndup[job]++ }
      }
      END {
        for (k in cnt) if (!(k in seen)) {
          split(k, a, SUBSEP); print a[2], drt[k, 1] > (out "/" a[1] ".ONLY_IN_DEST.txt"); extra[a[1]]++
        }
        for (job in nsrc) {
          printf "%-12s source %d files (%.1f GB) | ok %d | MISSING %d | SIZE MISMATCH %d", job, nsrc[job], bytes[job] / 1e9, ok[job], miss[job], nsize[job]
          if (mode != "size") printf " | HASH MISMATCH %d | READ ERRORS %d", nbad[job], nerr[job]
          printf "\n             (info: multiple copies %d | only in destination %d)\n", ndup[job], extra[job]
        }
      }' "$d" "$s"
  } | tee "$out/report.txt"

  problems=$(cat "$out"/*.MISSING.txt "$out"/*.SIZE_MISMATCH.txt \
                 "$out"/*.HASH_MISMATCH.txt "$out"/*.READ_ERRORS.txt 2>/dev/null | wc -l | tr -d ' ')
  echo "" | tee -a "$out/report.txt"
  if [ "$problems" -eq 0 ]; then
    echo "RESULT: OK — every source file has an intact copy ($tag)" | tee -a "$out/report.txt"
    echo "Details: $out"
    return 0
  else
    echo "RESULT: $problems PROBLEMS — details in $out" | tee -a "$out/report.txt"
    return 1
  fi
}

cmd_size() {
  load_config
  lock size
  echo "Listing source and destination files..."
  list_side src | awk -v OFS='\t' '{ print $0, "-" }' > "$WORK/src.size.tsv"
  list_side dst | awk -v OFS='\t' '{ print $0, "-" }' > "$WORK/dst.size.tsv"
  do_compare "$WORK/src.size.tsv" "$WORK/dst.size.tsv" size
}

cmd_compare() {
  local mode=$1 tag c
  check_mode "$mode"
  tag=$(tag_for "$mode")
  for c in hash-src hash-dst; do
    [ -e "$WORK/$c.pid" ] && alive "$(cat "$WORK/$c.pid")" && die "$c is still running: wait for it to finish (see status)"
  done
  [ -s "$WORK/src.hash.$tag.tsv" ] || die "source hashes ($tag) not found: run  hash-src $mode  first"
  [ -s "$WORK/dst.hash.$tag.tsv" ] || die "destination hashes ($tag) not found: run  hash-dst $mode  first"
  lock compare
  do_compare "$WORK/src.hash.$tag.tsv" "$WORK/dst.hash.$tag.tsv" "$tag"
}

cmd_status() {
  local f c p any=0
  for f in "$WORK"/*.pid; do
    [ -e "$f" ] || continue
    c=$(basename "$f" .pid); p=$(cat "$f")
    if alive "$p"; then
      any=1
      echo "== $c RUNNING (PID $p)"
      [ -e "$WORK/$c.log" ] && tail -n 4 "$WORK/$c.log" | sed 's/^/   /'
    else
      rm -f "$f"
    fi
  done
  [ "$any" = 0 ] && echo "Nothing running."
  echo ""
  echo "Completed hashes:"
  any=0
  for f in "$WORK"/src.hash.*.tsv "$WORK"/dst.hash.*.tsv; do
    [ -e "$f" ] || continue
    any=1; echo "   $(basename "$f")  ($(wc -l < "$f" | tr -d ' ') files, $(date -r "$f" '+%Y-%m-%d %H:%M'))"
  done
  [ "$any" = 0 ] && echo "   none"
  echo "Last log lines:"
  for f in "$WORK"/*.log; do [ -e "$f" ] && echo "   $(basename "$f"): $(tail -n 1 "$f")"; done
}

cmd_stop() {
  local f c p any=0
  for f in "$WORK"/*.pid; do
    [ -e "$f" ] || continue
    c=$(basename "$f" .pid); p=$(cat "$f")
    alive "$p" || { rm -f "$f"; continue; }
    any=1
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p"
    echo "Stopped $c (PID $p). Run it again to resume from the files not yet hashed."
  done
  [ "$any" = 0 ] && echo "Nothing running."
}

case "$1" in
  size)     cmd_size ;;
  hash-src) cmd_hash src "${2:-fast}" ;;
  hash-dst) cmd_hash dst "${2:-fast}" ;;
  compare)  cmd_compare "${2:-fast}" ;;
  status)   cmd_status ;;
  stop)     cmd_stop ;;
  *)        usage ;;
esac
