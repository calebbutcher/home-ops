#!/usr/bin/env bash
#
# nic-textfile-collector.sh — export the Broadcom `bnxt_en` driver counters that
# node_exporter's /proc-based network collector CAN'T see, so we can catch the
# TrueNAS uplink's *silent* NIC hang. Output is Prometheus text-exposition format
# for node_exporter's --collector.textfile.directory.
#
# WHY: the 2026-08-02 hang wedged the NIC with NO kernel log and NO change in the
# node_network_*_errs counters — carrier stayed "up", the box just stopped passing
# packets (kernel was still alive: it logged an iSCSI timeout 34s later). The card
# is a dual-port Broadcom NetXtreme (driver `bnxt_en`, NOT Mellanox), whose real
# health lives in `ethtool -S`: firmware-reset counts (`fw_reset_cnt`/`resets`),
# `*_fw_discards`, `missed_irqs`, `*_error*`/`*_discard*`. Those increment on the
# silent driver/firmware resets that PRECEDE a fatal wedge, so scraping them is our
# earliest reliable tell. `ethtool -S` runs on the HOST (no container netlink caps
# to worry about), same rationale as the sibling zfs-textfile-collector.sh.
#
# DEPLOY (TrueNAS SCALE 25.10) — same mechanism as zfs-textfile-collector.sh:
#   1. Copy onto the pool, e.g. /mnt/<pool>/scripts/nic-textfile-collector.sh, and
#      `chmod +x` it.
#   2. Set TEXTFILE_DIR to the host dir bind-mounted into the node_exporter Custom
#      App (the one already serving --collector.textfile.directory). It writes a
#      SEPARATE file (nic.prom) so it coexists with zfs.prom in that dir.
#   3. Schedule via System Settings → Advanced → Cron Jobs, run as root, `*/5 * * * *`.
#   Re-verify the cron after major TrueNAS upgrades (they can reset OS-level tweaks).
#
# On failure to read ANY interface it exits WITHOUT rewriting nic.prom, so the file
# goes stale and TrueNASNICCollectorStale fires — a dead pipeline must never read as
# "healthy".
#
# Env overrides:
#   TEXTFILE_DIR  output dir (default /var/lib/node_exporter/textfile)
#   NIC_IFACES    space-separated interfaces (default: bond01's slaves, else auto)
#   ETHTOOL_BIN   path to ethtool
#   KEEP_RE       egrep pattern of stat names to export (default below)

set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="${TEXTFILE_DIR}/nic.prom"
ETHTOOL="${ETHTOOL_BIN:-$(command -v ethtool || echo /usr/sbin/ethtool)}"
# Only the hang-relevant global counters — keeps cardinality low and skips the
# high-volume packet/byte stats. Matched case-insensitively against the stat name.
KEEP_RE="${KEEP_RE:-err|discard|drop|reset|timeout|miss|fw_|oob|buf|fatal|crc|fifo|no_buf|resource|stall|hang|recover|abort|nonzero}"

command -v "$ETHTOOL" >/dev/null 2>&1 || { echo "ethtool not found ($ETHTOOL)" >&2; exit 1; }
mkdir -p "$TEXTFILE_DIR"

# Interfaces to sample: the bond01 slaves (the real uplink) by default. Fall back to
# any bnxt_en interface if bond01 isn't present under a different name.
if [ -z "${NIC_IFACES:-}" ]; then
  if [ -r /sys/class/net/bond01/bonding/slaves ]; then
    NIC_IFACES="$(cat /sys/class/net/bond01/bonding/slaves)"
  else
    NIC_IFACES=""
    for d in /sys/class/net/*/device/driver; do
      [ -e "$d" ] || continue
      if [ "$(basename "$(readlink -f "$d")")" = "bnxt_en" ]; then
        NIC_IFACES="$NIC_IFACES $(basename "$(dirname "$(dirname "$d")")")"
      fi
    done
  fi
fi
NIC_IFACES="$(echo "$NIC_IFACES" | xargs)"   # trim
[ -n "$NIC_IFACES" ] || { echo "no interfaces to sample (set NIC_IFACES)" >&2; exit 1; }

NOW="$(date +%s)"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

samples=()   # "bnxt_stat{device=\"..\",stat=\"..\"} <int>"
read_ok=0
for ifc in $NIC_IFACES; do
  stats="$("$ETHTOOL" -S "$ifc" 2>/dev/null)" || { echo "ethtool -S $ifc failed" >&2; continue; }
  read_ok=1
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"            # strip leading whitespace
    case "$line" in
      ''|'NIC statistics:'*) continue ;;               # header
      \[*) continue ;;                                 # per-ring "[N]: ..." — skip, keep only global sums
    esac
    stat="${line%%:*}"
    val="${line#*: }"
    val="${val%%[[:space:]]*}"
    case "$val" in ''|*[!0-9]*) continue ;; esac       # integer counters only
    printf '%s' "$stat" | grep -qiE "$KEEP_RE" || continue
    samples+=("bnxt_stat{device=\"$ifc\",stat=\"$stat\"} $val")
  done <<< "$stats"
done

# If we couldn't read a single interface, leave the old file in place so it goes
# stale (TrueNASNICCollectorStale) instead of publishing an empty "all clear".
[ "$read_ok" -eq 1 ] || { echo "no interface readable, not rewriting $OUT" >&2; exit 1; }

{
  printf '# HELP bnxt_stat Selected Broadcom bnxt_en ethtool -S counters (global, per interface).\n'
  printf '# TYPE bnxt_stat counter\n'
  printf '%s\n' ${samples[@]+"${samples[@]}"}
  printf '# HELP bnxt_collector_last_run_timestamp Unix time this NIC collector last completed.\n'
  printf '# TYPE bnxt_collector_last_run_timestamp gauge\n'
  printf 'bnxt_collector_last_run_timestamp %s\n' "$NOW"
} >> "$TMP"

chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"
trap - EXIT
