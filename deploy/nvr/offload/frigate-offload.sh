#!/usr/bin/env bash
# Move the oldest Frigate recordings to the NAS once local usage passes a
# high-water mark. Runs from frigate-offload.timer.
#
# Safe by design:
#  - does nothing unless the NAS is actually mounted
#  - moves whole hour folders, oldest first, never the most recent ones
#  - rsync verifies each file before the local copy is removed
#  - only one run at a time (flock)
set -euo pipefail

CONF=${FRIGATE_OFFLOAD_CONF:-/etc/frigate-offload.env}
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"

: "${RECORD_DIR:?RECORD_DIR not set}"
: "${NAS_MOUNT:?NAS_MOUNT not set}"
NAS_SUBDIR=${NAS_SUBDIR:-recordings}
HIGH_WATER_GB=${HIGH_WATER_GB:-70}
LOW_WATER_GB=${LOW_WATER_GB:-60}
MIN_AGE_MINUTES=${MIN_AGE_MINUTES:-90}
FRIGATE_API=${FRIGATE_API:-}
DRY_RUN=${DRY_RUN:-0}

log() { echo "[frigate-offload] $*"; }

exec 9>/run/frigate-offload.lock
flock -n 9 || { log "another run is in progress, exiting"; exit 0; }

if ! mountpoint -q "$NAS_MOUNT"; then
  log "ERROR: $NAS_MOUNT is not mounted; not moving anything"
  exit 1
fi
if [[ ! -d "$RECORD_DIR" ]]; then
  log "nothing to do: $RECORD_DIR does not exist yet"
  exit 0
fi

GB=$((1024 * 1024 * 1024))
high=$((HIGH_WATER_GB * GB))
low=$((LOW_WATER_GB * GB))
used() { du -sb "$RECORD_DIR" | cut -f1; }

usage=$(used)
log "local recordings: $((usage / GB))GB (high-water ${HIGH_WATER_GB}GB, target ${LOW_WATER_GB}GB)"
if (( usage < high )); then
  exit 0
fi

dest_root="$NAS_MOUNT/$NAS_SUBDIR"
mkdir -p "$dest_root"
cutoff=$(date -d "-${MIN_AGE_MINUTES} minutes" +%s)
moved=0

# Frigate layout: RECORD_DIR/YYYY-MM-DD/HH/<camera>/MM.SS.mp4
while IFS= read -r hour_dir; do
  rel=${hour_dir#"$RECORD_DIR"/}            # YYYY-MM-DD/HH
  day=${rel%/*}; hour=${rel#*/}
  # Frigate names folders in UTC.
  hour_ts=$(date -u -d "$day $hour:00:00" +%s 2>/dev/null) || continue
  if (( hour_ts + 3600 > cutoff )); then
    break                                    # everything after this is newer
  fi

  log "moving $rel to NAS"
  if [[ "$DRY_RUN" == 1 ]]; then
    moved=$((moved + 1)); continue
  fi
  mkdir -p "$dest_root/$rel"
  # -rt, not -a: the NAS is NFS with root squash, so chown/chmod would fail.
  rsync -rt --remove-source-files "$hour_dir/" "$dest_root/$rel/"
  find "$hour_dir" -depth -type d -empty -delete
  rmdir "$RECORD_DIR/$day" 2>/dev/null || true
  moved=$((moved + 1))

  usage=$(used)
  if (( usage < low )); then
    break
  fi
done < <(find "$RECORD_DIR" -mindepth 2 -maxdepth 2 -type d | sort)

log "moved $moved hour folder(s); local recordings now $(( $(used) / GB ))GB"

if (( moved > 0 )) && [[ -n "$FRIGATE_API" && "$DRY_RUN" != 1 ]]; then
  # Remove DB rows whose files were moved. force=true is needed because a
  # single run can move more than half of the local segments, which trips
  # Frigate's safety check. It only deletes rows for files that are missing.
  if curl -fsS -m 30 -X POST "$FRIGATE_API/api/media/sync" \
       -H 'Content-Type: application/json' \
       -d '{"dry_run": false, "media_types": ["recordings"], "force": true}' >/dev/null; then
    log "asked Frigate to sync its recordings index"
  else
    log "WARNING: could not reach Frigate at $FRIGATE_API to sync the index"
  fi
fi
