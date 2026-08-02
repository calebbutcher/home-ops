#!/usr/bin/env bash
#
# zfs-textfile-collector.sh — export the ZFS pool health that node_exporter's
# built-in zfs collector CAN'T: scrub status, fragmentation, capacity, and
# per-vdev read/write/checksum errors. Output is Prometheus text-exposition
# format for node_exporter's --collector.textfile.directory.
#
# WHY: node_exporter reads /proc/spl/kstat/zfs, which gives pool state, ARC and
# dataset I/O — but scrub/frag/capacity/vdev-errors live only in the userspace
# `zpool status` / `zpool list` output. This script runs the HOST's own zpool
# binaries (so there is no libzfs/kernel version mismatch like a containerized
# zfs_exporter would hit) and writes atomically so node_exporter never reads a
# half-written file.
#
# DEPLOY (TrueNAS SCALE 25.10):
#   1. Copy onto the pool, e.g. /mnt/<pool>/scripts/zfs-textfile-collector.sh, and
#      `chmod +x` it.
#   2. Set TEXTFILE_DIR to the host dir bind-mounted into the node_exporter Custom
#      App, which must run with --collector.textfile.directory=<in-container dir>.
#   3. Schedule via System Settings → Advanced → Cron Jobs, run as root, `*/5 * * * *`.
#   Re-verify the app edit + cron after major TrueNAS upgrades (they can reset
#   OS-level tweaks).
#
# On any zpool command failure this exits WITHOUT rewriting the .prom, so the file
# goes stale and TrueNASZFSCollectorStale fires — a dead pipeline must never read
# as "healthy".
#
# Env overrides: TEXTFILE_DIR (output dir), ZPOOL_BIN (path to zpool).

set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="${TEXTFILE_DIR}/zfs.prom"
ZPOOL="${ZPOOL_BIN:-$(command -v zpool || echo /usr/sbin/zpool)}"

command -v "$ZPOOL" >/dev/null 2>&1 || { echo "zpool not found ($ZPOOL)" >&2; exit 1; }
mkdir -p "$TEXTFILE_DIR"

# -Hp = tab-separated, no header, parsable (bytes for sizes; cap/frag as integers).
# Pool health is intentionally omitted here — node_zfs_zpool_state already covers it.
LIST="$("$ZPOOL" list -Hp -o name,size,alloc,free,cap,frag,dedup 2>/dev/null)" \
  || { echo "zpool list failed" >&2; exit 1; }
# -p = exact integer READ/WRITE/CKSUM counters instead of 1.2K-style suffixes.
STATUS="$("$ZPOOL" status -p 2>/dev/null)" \
  || { echo "zpool status failed" >&2; exit 1; }

NOW="$(date +%s)"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# ---------------------------------------------------------------- pool-level
cap=(); frag=(); size=(); alloc=(); free=(); dedup=()
while IFS=$'\t' read -r name psize palloc pfree pcap pfrag pdedup; do
  [ -n "$name" ] || continue
  pdedup="${pdedup%x}"   # strip a trailing 'x' if this zfs build keeps it
  cap+=("zfs_zpool_capacity_ratio{pool=\"$name\"} $(awk "BEGIN{print $pcap/100}")")
  size+=("zfs_zpool_size_bytes{pool=\"$name\"} $psize")
  alloc+=("zfs_zpool_allocated_bytes{pool=\"$name\"} $palloc")
  free+=("zfs_zpool_free_bytes{pool=\"$name\"} $pfree")
  case "$pfrag" in
    ''|'-') : ;;
    *) frag+=("zfs_zpool_fragmentation_ratio{pool=\"$name\"} $(awk "BEGIN{print $pfrag/100}")") ;;
  esac
  case "$pdedup" in
    ''|'-') : ;;
    *) dedup+=("zfs_zpool_dedup_ratio{pool=\"$name\"} $pdedup") ;;
  esac
done <<< "$LIST"

# ---------------------------------------------------------------- per-vdev errors
# Walk each pool's `config:` block; a real vdev row has NAME STATE READ WRITE CKSUM
# with the last three as integers. Section labels (logs/cache/spares) lack them.
vread=(); vwrite=(); vcksum=()
while IFS=$'\t' read -r pool vdev r w c; do
  [ -n "$pool" ] || continue
  vread+=("zfs_zpool_vdev_read_errors{pool=\"$pool\",vdev=\"$vdev\"} $r")
  vwrite+=("zfs_zpool_vdev_write_errors{pool=\"$pool\",vdev=\"$vdev\"} $w")
  vcksum+=("zfs_zpool_vdev_checksum_errors{pool=\"$pool\",vdev=\"$vdev\"} $c")
done <<< "$(awk '
  /^[[:space:]]*pool:/     {pool=$2; inc=0; next}
  /^[[:space:]]*config:/   {inc=1; next}
  /^[[:space:]]*errors:/   {inc=0; next}
  inc==1 && $1!="NAME" && NF>=5 && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ {
    printf "%s\t%s\t%s\t%s\t%s\n", pool, $1, $3, $4, $5
  }
' <<< "$STATUS")"

# ---------------------------------------------------------------- scrub state
# scan line examples:
#   scrub repaired 0B in 00:12:34 with 0 errors on Sun Jan 12 04:12:34 2026  -> finished
#   scrub in progress since ...                                              -> scanning
#   none requested                                                           -> idle
sstate=(); slast=(); serr=()
pool=""
scan_re='with ([0-9]+) errors on (.+)$'
while IFS= read -r line; do
  case "$line" in
    *"pool:"*) pool="$(awk '{print $2}' <<< "$line")" ;;
    *"scan:"*)
      [ -n "$pool" ] || continue
      s="${line#*scan:}"
      st=0
      printf '%s' "$s" | grep -qi 'scrub in progress' && st=1
      printf '%s' "$s" | grep -qi 'scrub canceled'    && st=3
      if printf '%s' "$s" | grep -qi 'scrub repaired'; then
        st=2
        if [[ "$s" =~ $scan_re ]]; then
          serr+=("zfs_zpool_scrub_errors{pool=\"$pool\"} ${BASH_REMATCH[1]}")
          if ep="$(date -d "${BASH_REMATCH[2]}" +%s 2>/dev/null)"; then
            slast+=("zfs_zpool_scrub_last_finish_timestamp{pool=\"$pool\"} $ep")
          fi
        fi
      fi
      sstate+=("zfs_zpool_scrub_state{pool=\"$pool\"} $st")
      ;;
  esac
done <<< "$STATUS"

# ---------------------------------------------------------------- emit
emit() {  # emit <metric> <help> <sample>...
  local name="$1" help="$2"; shift 2
  [ "$#" -gt 0 ] || return 0
  printf '# HELP %s %s\n' "$name" "$help"
  printf '# TYPE %s gauge\n' "$name"
  printf '%s\n' "$@"
}

# ${arr[@]+"${arr[@]}"} = expand the array, or nothing if empty, safe under set -u.
{
  emit zfs_zpool_capacity_ratio       "Fraction of pool capacity used (zpool list CAP/100)."      ${cap[@]+"${cap[@]}"}
  emit zfs_zpool_fragmentation_ratio  "Pool fragmentation (zpool list FRAG/100)."                 ${frag[@]+"${frag[@]}"}
  emit zfs_zpool_size_bytes           "Total pool size in bytes."                                 ${size[@]+"${size[@]}"}
  emit zfs_zpool_allocated_bytes      "Allocated pool space in bytes."                            ${alloc[@]+"${alloc[@]}"}
  emit zfs_zpool_free_bytes           "Free pool space in bytes."                                 ${free[@]+"${free[@]}"}
  emit zfs_zpool_dedup_ratio          "Pool deduplication ratio."                                 ${dedup[@]+"${dedup[@]}"}
  emit zfs_zpool_vdev_read_errors     "Per-vdev cumulative read errors (zpool status)."           ${vread[@]+"${vread[@]}"}
  emit zfs_zpool_vdev_write_errors    "Per-vdev cumulative write errors (zpool status)."          ${vwrite[@]+"${vwrite[@]}"}
  emit zfs_zpool_vdev_checksum_errors "Per-vdev cumulative checksum errors (zpool status)."       ${vcksum[@]+"${vcksum[@]}"}
  emit zfs_zpool_scrub_state          "Scrub state: 0 idle/none, 1 scanning, 2 finished, 3 canceled." ${sstate[@]+"${sstate[@]}"}
  emit zfs_zpool_scrub_last_finish_timestamp "Unix time the last scrub finished."                 ${slast[@]+"${slast[@]}"}
  emit zfs_zpool_scrub_errors         "Unrepaired errors found by the last completed scrub."      ${serr[@]+"${serr[@]}"}
  printf '# HELP zfs_zpool_collector_last_run_timestamp Unix time this collector last completed.\n'
  printf '# TYPE zfs_zpool_collector_last_run_timestamp gauge\n'
  printf 'zfs_zpool_collector_last_run_timestamp %s\n' "$NOW"
} >> "$TMP"

chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"
trap - EXIT
