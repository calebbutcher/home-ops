#!/usr/bin/env python3
"""Generate TrueNAS System + ZFS Grafana dashboard ConfigMaps for home-ops.
Matches the repo convention: schemaVersion 39, a $datasource template variable
defaulting to the local Prometheus, label grafana_dashboard: "1", panels scoped
to job="truenas-node".

Run `python3 scripts/monitoring/gen_truenas_dashboards.py` from anywhere; it
rewrites kubernetes/apps/monitoring/truenas/dashboard-{system,zfs}.yaml in place.
The ZFS pool health panels (capacity/fragmentation/scrub/per-vdev errors) are fed
by the node_exporter textfile collector installed via
scripts/truenas/zfs-textfile-collector.sh (metrics prefixed zfs_zpool_*).
"""
import json, os

# Every panel and target points at the $datasource variable rather than a fixed
# uid, so these dashboards can be flipped between the local Prometheus (~2d
# retention) and Thanos (long-term, via thanos-query-frontend) from the picker.
# TrueNAS metrics come from node_exporter scraped by Prometheus, so the Thanos
# sidecar ships them to RustFS like everything else — the history is there, the
# dashboards just had no way to reach it. See DATASOURCE_VAR below.
DS = {"type": "prometheus", "uid": "${datasource}"}

# Grafana renders this as the "Datasource" picker at the top of the dashboard.
# query: "prometheus" lists every datasource of that *type*, which is both the
# built-in Prometheus and Thanos (the Thanos datasource is type prometheus — it
# speaks the same API). Default stays the local Prometheus: the 6h default window
# is well inside local retention, and Thanos costs an object-store round trip.
DATASOURCE_VAR = {
    "name": "datasource", "label": "Datasource", "type": "datasource",
    "query": "prometheus",
    "current": {"selected": False, "text": "Prometheus", "value": "prometheus"},
    "hide": 0, "includeAll": False, "multi": False, "options": [],
    "refresh": 1, "regex": "", "skipUrlSync": False,
}
JOB = 'job="truenas-node"'
NIC = 'device=~"bond01|enp65s0f.*"'
# Repo-relative: this file lives at scripts/monitoring/, the manifests at
# kubernetes/apps/monitoring/ — resolve from __file__ so it's machine-independent.
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..",
                                    "kubernetes", "apps", "monitoring"))

def tgt(expr, legend=None, refid="A", instant=False):
    t = {"refId": refid, "datasource": DS, "expr": expr}
    if legend is not None:
        t["legendFormat"] = legend
    if instant:
        t["instant"] = True
        t["range"] = False
    return t

def stat(pid, title, x, y, w, h, expr, unit, steps):
    return {
        "id": pid, "type": "stat", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {
            "unit": unit, "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "value", "graphMode": "area", "textMode": "auto",
                    "justifyMode": "auto"},
        "targets": [tgt(expr)],
    }

def ts(pid, title, x, y, w, h, targets, unit, stack=False, fillOpacity=10, minv=None):
    custom = {"drawStyle": "line", "lineInterpolation": "smooth", "lineWidth": 1,
              "fillOpacity": fillOpacity, "gradientMode": "opacity", "spanNulls": False,
              "showPoints": "never", "pointSize": 5,
              "stacking": {"mode": "normal" if stack else "none", "group": "A"},
              "axisPlacement": "auto", "axisColorMode": "text", "scaleDistribution": {"type": "linear"}}
    defaults = {"unit": unit, "custom": custom, "color": {"mode": "palette-classic"},
                "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]}}
    if minv is not None:
        defaults["min"] = minv
    return {
        "id": pid, "type": "timeseries", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"tooltip": {"mode": "multi", "sort": "desc"},
                    "legend": {"displayMode": "table", "placement": "bottom",
                               "calcs": ["last", "max"]}},
        "targets": targets,
    }

def table(pid, title, x, y, w, h, expr, unit, steps):
    return {
        "id": pid, "type": "table", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {
            "unit": unit, "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": steps},
            "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": True}},
            "overrides": []},
        "options": {"showHeader": True, "cellHeight": "sm",
                    "sortBy": [{"displayName": "Value", "desc": True}]},
        "targets": [tgt(expr, instant=True)],
        "transformations": [
            {"id": "labelsToFields", "options": {"mode": "columns"}},
            {"id": "organize", "options": {"excludeByName": {"Time": True, "job": True,
             "instance": True, "host": True, "device": True, "fstype": True},
             "renameByName": {"Value": "Used %"}}},
        ],
    }

def dashboard(uid, title, tags, panels):
    return {
        "annotations": {"list": []}, "editable": True, "graphTooltip": 1,
        "schemaVersion": 39, "version": 1, "uid": uid, "title": title, "tags": tags,
        "time": {"from": "now-6h", "to": "now"}, "refresh": "30s",
        "templating": {"list": [DATASOURCE_VAR]}, "panels": panels,
    }

def write_cm(name, key, dash):
    j = json.dumps(dash, indent=2)
    body = "\n".join("    " + ln for ln in j.splitlines())
    doc = (
        "---\n"
        f"# Auto-provisioned Grafana dashboard for the TrueNAS host (job=truenas-node).\n"
        f"# Imported by the kube-prometheus-stack Grafana sidecar via the\n"
        f"# grafana_dashboard label. Generated from scripts/monitoring/gen_truenas_dashboards.py\n"
        f"# — edit the generator, not this file, or the next run silently reverts you.\n"
        f"#\n"
        f"# $datasource defaults to the local Prometheus (~2d retention) and can be switched\n"
        f"# to Thanos in the picker for long-range history. Same convention as the Postgres\n"
        f"# and Traefik dashboards.\n"
        "apiVersion: v1\n"
        "kind: ConfigMap\n"
        "metadata:\n"
        f"  name: {name}\n"
        "  namespace: monitoring\n"
        "  labels:\n"
        "    grafana_dashboard: \"1\"\n"
        "data:\n"
        f"  {key}: |\n"
        f"{body}\n"
    )
    # normalize file name
    fn = {"truenas-system-dashboard": "dashboard-system.yaml",
          "truenas-zfs-dashboard": "dashboard-zfs.yaml"}[name]
    path = os.path.join(REPO, "truenas", fn)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(doc)
    # sanity: embedded json parses
    json.loads("\n".join(ln[4:] for ln in body.splitlines()))
    print("wrote", path, f"({len(doc)} bytes)")

GREEN = [{"color": "green", "value": None}]

# ----------------------------------------------------------------- SYSTEM
sp = []
sp.append(stat(1, "CPU Busy", 0, 0, 6, 4,
    f'(1 - avg(rate(node_cpu_seconds_total{{{JOB},mode="idle"}}[$__rate_interval]))) * 100',
    "percent", [{"color": "green", "value": None}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]))
sp.append(stat(2, "Load (1m)", 6, 0, 6, 4, f'node_load1{{{JOB}}}', "short", GREEN))
sp.append(stat(3, "RAM Used", 12, 0, 6, 4,
    f'(1 - node_memory_MemAvailable_bytes{{{JOB}}} / node_memory_MemTotal_bytes{{{JOB}}}) * 100',
    "percent", [{"color": "green", "value": None}, {"color": "yellow", "value": 80}, {"color": "red", "value": 95}]))
sp.append(stat(4, "Uptime", 18, 0, 6, 4,
    f'node_time_seconds{{{JOB}}} - node_boot_time_seconds{{{JOB}}}', "dtdurations", GREEN))
sp.append(ts(5, "CPU by mode", 0, 4, 12, 8,
    [tgt(f'avg by (mode) (rate(node_cpu_seconds_total{{{JOB},mode!="idle"}}[$__rate_interval])) * 100', "{{mode}}")],
    "percent", stack=True, fillOpacity=30))
sp.append(ts(6, "Load average", 12, 4, 12, 8,
    [tgt(f'node_load1{{{JOB}}}', "1m", "A"), tgt(f'node_load5{{{JOB}}}', "5m", "B"),
     tgt(f'node_load15{{{JOB}}}', "15m", "C")], "short"))
sp.append(ts(7, "Memory", 0, 12, 12, 8,
    [tgt(f'node_memory_MemTotal_bytes{{{JOB}}}', "Total", "A"),
     tgt(f'node_memory_MemAvailable_bytes{{{JOB}}}', "Available", "B"),
     tgt(f'node_zfs_arc_size{{{JOB}}}', "ZFS ARC", "C"),
     tgt(f'node_memory_MemFree_bytes{{{JOB}}}', "Free", "D")], "bytes", minv=0))
sp.append(ts(8, "Network throughput", 12, 12, 12, 8,
    [tgt(f'rate(node_network_receive_bytes_total{{{JOB},{NIC}}}[$__rate_interval]) * 8', "{{device}} rx", "A"),
     tgt(f'rate(node_network_transmit_bytes_total{{{JOB},{NIC}}}[$__rate_interval]) * 8', "{{device}} tx", "B")],
    "bps", minv=0))
sp.append(ts(9, "Disk IOPS", 0, 20, 12, 8,
    [tgt(f'rate(node_disk_reads_completed_total{{{JOB}}}[$__rate_interval])', "{{device}} read", "A"),
     tgt(f'rate(node_disk_writes_completed_total{{{JOB}}}[$__rate_interval])', "{{device}} write", "B")],
    "iops", minv=0))
sp.append(ts(10, "Disk throughput", 12, 20, 12, 8,
    [tgt(f'rate(node_disk_read_bytes_total{{{JOB}}}[$__rate_interval])', "{{device}} read", "A"),
     tgt(f'rate(node_disk_written_bytes_total{{{JOB}}}[$__rate_interval])', "{{device}} write", "B")],
    "Bps", minv=0))
sp.append(ts(11, "Temperatures", 0, 28, 12, 8,
    [tgt(f'node_hwmon_temp_celsius{{{JOB}}}', "{{chip}} {{sensor}}")], "celsius"))
sp.append(ts(12, "Network errors / drops", 12, 28, 12, 8,
    [tgt(f'rate(node_network_receive_errs_total{{{JOB},{NIC}}}[$__rate_interval]) + rate(node_network_transmit_errs_total{{{JOB},{NIC}}}[$__rate_interval])', "{{device}} errs", "A"),
     tgt(f'rate(node_network_receive_drop_total{{{JOB},{NIC}}}[$__rate_interval]) + rate(node_network_transmit_drop_total{{{JOB},{NIC}}}[$__rate_interval])', "{{device}} drops", "B")],
    "pps", minv=0))
write_cm("truenas-system-dashboard", "truenas-system.json",
         dashboard("truenas-system", "TrueNAS / System", ["truenas", "node"], sp))

# ----------------------------------------------------------------- ZFS
zp = []
zp.append(stat(1, "Unhealthy pools", 0, 0, 6, 4,
    f'count(node_zfs_zpool_state{{{JOB},state=~"degraded|faulted|unavail|removed|suspended"}} == 1) or vector(0)',
    "short", [{"color": "green", "value": None}, {"color": "red", "value": 1}]))
zp.append(stat(2, "ARC hit ratio", 6, 0, 6, 4,
    f'sum(rate(node_zfs_arc_hits{{{JOB}}}[$__rate_interval])) / (sum(rate(node_zfs_arc_hits{{{JOB}}}[$__rate_interval])) + sum(rate(node_zfs_arc_misses{{{JOB}}}[$__rate_interval])))',
    "percentunit", [{"color": "red", "value": None}, {"color": "yellow", "value": 0.8}, {"color": "green", "value": 0.95}]))
zp.append(stat(3, "ARC size", 12, 0, 6, 4, f'node_zfs_arc_size{{{JOB}}}', "bytes", GREEN))
zp.append(stat(4, "L2ARC size", 18, 0, 6, 4, f'node_zfs_arc_l2_size{{{JOB}}}', "bytes", GREEN))
zp.append({
    "id": 5, "type": "table", "title": "Pool state", "datasource": DS,
    "gridPos": {"h": 4, "w": 24, "x": 0, "y": 4},
    "fieldConfig": {"defaults": {"custom": {"align": "auto", "filterable": True}}, "overrides": []},
    "options": {"showHeader": True, "cellHeight": "sm"},
    "targets": [tgt(f'node_zfs_zpool_state{{{JOB}}} == 1', instant=True)],
    "transformations": [
        {"id": "labelsToFields", "options": {"mode": "columns"}},
        {"id": "organize", "options": {"excludeByName": {"Time": True, "job": True,
         "instance": True, "host": True, "Value": True},
         "renameByName": {"zpool": "Pool", "state": "State"}}}],
})
zp.append(ts(6, "ARC size vs target", 0, 8, 12, 8,
    [tgt(f'node_zfs_arc_size{{{JOB}}}', "Current", "A"),
     tgt(f'node_zfs_arc_c{{{JOB}}}', "Target (c)", "B"),
     tgt(f'node_zfs_arc_c_max{{{JOB}}}', "Max", "C")], "bytes", minv=0))
zp.append(ts(7, "ARC hits vs misses", 12, 8, 12, 8,
    [tgt(f'rate(node_zfs_arc_hits{{{JOB}}}[$__rate_interval])', "hits/s", "A"),
     tgt(f'rate(node_zfs_arc_misses{{{JOB}}}[$__rate_interval])', "misses/s", "B")], "ops", minv=0))
zp.append(ts(8, "ARC hit ratio", 0, 16, 12, 8,
    [tgt(f'sum(rate(node_zfs_arc_hits{{{JOB}}}[$__rate_interval])) / (sum(rate(node_zfs_arc_hits{{{JOB}}}[$__rate_interval])) + sum(rate(node_zfs_arc_misses{{{JOB}}}[$__rate_interval])))', "ARC")],
    "percentunit", minv=0))
zp.append(ts(9, "L2ARC hit ratio", 12, 16, 12, 8,
    [tgt(f'sum(rate(node_zfs_arc_l2_hits{{{JOB}}}[$__rate_interval])) / (sum(rate(node_zfs_arc_l2_hits{{{JOB}}}[$__rate_interval])) + sum(rate(node_zfs_arc_l2_misses{{{JOB}}}[$__rate_interval])))', "L2ARC")],
    "percentunit", minv=0))
zp.append(ts(10, "Pool throughput", 0, 24, 12, 8,
    [tgt(f'sum by (zpool) (rate(node_zfs_zpool_dataset_nread{{{JOB}}}[$__rate_interval]))', "{{zpool}} read", "A"),
     tgt(f'sum by (zpool) (rate(node_zfs_zpool_dataset_nwritten{{{JOB}}}[$__rate_interval]))', "{{zpool}} write", "B")],
    "Bps", minv=0))
zp.append(ts(11, "Pool IOPS", 12, 24, 12, 8,
    [tgt(f'sum by (zpool) (rate(node_zfs_zpool_dataset_reads{{{JOB}}}[$__rate_interval]))', "{{zpool}} read", "A"),
     tgt(f'sum by (zpool) (rate(node_zfs_zpool_dataset_writes{{{JOB}}}[$__rate_interval]))', "{{zpool}} write", "B")],
    "iops", minv=0))
zp.append(table(12, "Dataset usage (top)", 0, 32, 24, 10,
    f'(1 - node_filesystem_avail_bytes{{{JOB},fstype="zfs",mountpoint!~"/|/boot.*|/conf|/audit|/home|/data|/mnt/.ix-apps.*"}} / node_filesystem_size_bytes{{{JOB},fstype="zfs",mountpoint!~"/|/boot.*|/conf|/audit|/home|/data|/mnt/.ix-apps.*"}}) * 100',
    "percent", [{"color": "green", "value": None}, {"color": "yellow", "value": 80}, {"color": "red", "value": 90}]))

# ---- ZFS health (fed by scripts/truenas/zfs-textfile-collector.sh -> zfs_zpool_*) ----
zp.append(stat(13, "Pool capacity", 0, 42, 6, 4,
    f'max(zfs_zpool_capacity_ratio{{{JOB}}})', "percentunit",
    [{"color": "green", "value": None}, {"color": "yellow", "value": 0.8}, {"color": "red", "value": 0.9}]))
zp.append(stat(14, "Fragmentation", 6, 42, 6, 4,
    f'max(zfs_zpool_fragmentation_ratio{{{JOB}}})', "percentunit",
    [{"color": "green", "value": None}, {"color": "yellow", "value": 0.5}, {"color": "red", "value": 0.7}]))
zp.append(stat(15, "Since last scrub", 12, 42, 6, 4,
    f'time() - max(zfs_zpool_scrub_last_finish_timestamp{{{JOB}}})', "dtdurations",
    [{"color": "green", "value": None}, {"color": "yellow", "value": 2592000}, {"color": "red", "value": 3024000}]))
zp.append(stat(16, "Vdev errors (24h)", 18, 42, 6, 4,
    f'sum(increase(zfs_zpool_vdev_read_errors{{{JOB}}}[24h]) + increase(zfs_zpool_vdev_write_errors{{{JOB}}}[24h]) + increase(zfs_zpool_vdev_checksum_errors{{{JOB}}}[24h])) or vector(0)',
    "short", [{"color": "green", "value": None}, {"color": "red", "value": 1}]))
# Scrub state per pool (0 idle/none, 1 scanning, 2 finished, 3 canceled), value-mapped.
zp.append({
    "id": 17, "type": "table", "title": "Scrub state", "datasource": DS,
    "gridPos": {"h": 8, "w": 12, "x": 0, "y": 46},
    "fieldConfig": {"defaults": {"custom": {"align": "auto", "filterable": True}},
        "overrides": [
            {"matcher": {"id": "byName", "options": "State"},
             "properties": [{"id": "mappings", "value": [{"type": "value", "options": {
                 "0": {"text": "idle", "color": "green"},
                 "1": {"text": "scanning", "color": "blue"},
                 "2": {"text": "finished", "color": "green"},
                 "3": {"text": "canceled", "color": "yellow"}}}]},
                 {"id": "custom.cellOptions", "value": {"type": "color-text"}}]}]},
    "options": {"showHeader": True, "cellHeight": "sm"},
    "targets": [tgt(f'zfs_zpool_scrub_state{{{JOB}}}', instant=True)],
    "transformations": [
        {"id": "labelsToFields", "options": {"mode": "columns"}},
        {"id": "organize", "options": {"excludeByName": {"Time": True, "job": True,
         "instance": True, "host": True},
         "renameByName": {"pool": "Pool", "Value": "State"}}}],
})
# Per-vdev error counters — three instant queries merged into read/write/cksum columns.
zp.append({
    "id": 18, "type": "table", "title": "Per-vdev errors", "datasource": DS,
    "gridPos": {"h": 8, "w": 12, "x": 12, "y": 46},
    "fieldConfig": {"defaults": {
        "custom": {"align": "auto", "cellOptions": {"type": "color-background"}, "filterable": True},
        "color": {"mode": "thresholds"},
        "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]}},
        "overrides": [
            {"matcher": {"id": "byName", "options": "Pool"},
             "properties": [{"id": "custom.cellOptions", "value": {"type": "auto"}}]},
            {"matcher": {"id": "byName", "options": "vdev"},
             "properties": [{"id": "custom.cellOptions", "value": {"type": "auto"}}]}]},
    "options": {"showHeader": True, "cellHeight": "sm",
                "sortBy": [{"displayName": "Cksum", "desc": True}]},
    "targets": [
        tgt(f'zfs_zpool_vdev_read_errors{{{JOB}}}', refid="A", instant=True),
        tgt(f'zfs_zpool_vdev_write_errors{{{JOB}}}', refid="B", instant=True),
        tgt(f'zfs_zpool_vdev_checksum_errors{{{JOB}}}', refid="C", instant=True)],
    "transformations": [
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {"excludeByName": {"Time": True, "job": True,
         "instance": True, "host": True},
         "renameByName": {"pool": "Pool", "vdev": "vdev",
                          "Value #A": "Read", "Value #B": "Write", "Value #C": "Cksum"}}}],
})
zp.append(ts(19, "Pool capacity", 0, 54, 12, 8,
    [tgt(f'zfs_zpool_capacity_ratio{{{JOB}}}', "{{pool}}")], "percentunit", minv=0))
zp.append(ts(20, "Fragmentation", 12, 54, 12, 8,
    [tgt(f'zfs_zpool_fragmentation_ratio{{{JOB}}}', "{{pool}}")], "percentunit", minv=0))
zp.append(ts(21, "Per-vdev errors", 0, 62, 24, 8,
    [tgt(f'increase(zfs_zpool_vdev_checksum_errors{{{JOB}}}[$__rate_interval])', "{{pool}}/{{vdev}} cksum", "A"),
     tgt(f'increase(zfs_zpool_vdev_read_errors{{{JOB}}}[$__rate_interval])', "{{pool}}/{{vdev}} read", "B"),
     tgt(f'increase(zfs_zpool_vdev_write_errors{{{JOB}}}[$__rate_interval])', "{{pool}}/{{vdev}} write", "C")],
    "short", minv=0))
write_cm("truenas-zfs-dashboard", "truenas-zfs.json",
         dashboard("truenas-zfs", "TrueNAS / ZFS", ["truenas", "zfs"], zp))

print("OK")
