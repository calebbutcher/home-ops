#!/usr/bin/env python3
"""Generate the "Disks / SMART" Grafana dashboard ConfigMap for home-ops.

Covers every disk on the 4 Proxmox hosts and TrueNAS, fed by the `smartctl` scrape
job (smartctl_exporter on each host; see docs/smart-monitoring.md) and the
`smartctl:device_error_count` recording rule in
kube-prometheus-stack/prometheusrule-smart.yaml.

Same conventions as gen_truenas_dashboards.py: schemaVersion 39, a $datasource
picker defaulting to the local Prometheus, label grafana_dashboard: "1". No disk
identity is written into the JSON: model and serial come from the live
`smartctl_device` info metric at query time.

Run `python3 scripts/monitoring/gen_smart_dashboard.py` from anywhere; it rewrites
kubernetes/apps/monitoring/smart/dashboard.yaml in place.
"""
import json
import os

DS = {"type": "prometheus", "uid": "${datasource}"}
DATASOURCE_VAR = {
    "name": "datasource", "label": "Datasource", "type": "datasource",
    "query": "prometheus",
    "current": {"selected": False, "text": "Prometheus", "value": "prometheus"},
    "hide": 0, "includeAll": False, "multi": False, "options": [],
    "refresh": 1, "regex": "", "skipUrlSync": False,
}
HOST_VAR = {
    "name": "host", "label": "Host", "type": "query", "datasource": DS,
    "query": {"query": 'label_values(up{job="smartctl"}, host)', "refId": "host"},
    "definition": 'label_values(up{job="smartctl"}, host)',
    "current": {"selected": True, "text": ["All"], "value": ["$__all"]},
    "hide": 0, "includeAll": True, "allValue": ".*", "multi": True, "options": [],
    "refresh": 2, "regex": "", "skipUrlSync": False, "sort": 1,
}

SEL = 'job="smartctl", host=~"$host"'


def err(extra=""):
    """The recording-rule series, scoped to $host plus any extra matcher."""
    return 'smartctl:device_error_count{host=~"$host"' + (", " + extra if extra else "") + "}"


ERR = err()
# Readable names for the `counter` label, used by the table headers and chart legends.
COUNTER_NAMES = {
    "ata_5": "Realloc (5)",
    "ata_183": "Runtime bad blk (183)",
    "ata_187": "Uncorrectable (187)",
    "ata_197": "Pending (197)",
    "ata_198": "Offline unc (198)",
    "nvme_media_errors": "NVMe media err",
    "scsi_grown_defects": "SCSI grown defects",
    "scsi_read_uncorrected": "SCSI read uncorrected",
    "scsi_write_uncorrected": "SCSI write uncorrected",
}


def named(expr):
    """Add a `counter_name` label with the readable name of each counter."""
    for counter, name in COUNTER_NAMES.items():
        expr = f'label_replace({expr}, "counter_name", "{name}", "counter", "{counter}")'
    return expr


def with_disk(expr):
    """Add the short `disk` name (osd.N · sdX, or the device) from the recording rule."""
    return (f'({expr}) * on (host, device) group_left (disk) '
            f'smartctl:device_display_info{{host=~"$host"}}')


TEMP = f'smartctl_device_temperature{{{SEL}, temperature_type="current"}}'
# Share of rated endurance used, 0-100, whatever the interface:
#   NVMe   percentage_used (spec-defined)
#   SAS    percentage used endurance indicator (exporter >= 0.15 only)
#   SATA   100 - normalized VALUE of the vendor's wear attribute: 177 Wear_Leveling_Count
#          (Samsung), 202 Percent_Lifetime_Remain (Crucial/Micron), 231 SSD_Life_Left,
#          233 Media_Wearout_Indicator (Intel). Restricted to disks with no rotation
#          rate, because some HDDs reuse 202 for an unrelated attribute. `min` so that
#          when a drive exposes more than one of these, the worst remaining life wins.
WEAR = (
    f'max by (host, device) (smartctl_device_percentage_used{{{SEL}}})'
    f' or max by (host, device) (smartctl_scsi_percentage_used_endurance_indicator{{{SEL}}})'
    f' or (100 - min by (host, device) ('
    f'smartctl_device_attribute{{{SEL}, attribute_value_type="value", attribute_id=~"177|202|231|233"}}'
    f' unless on (instance, device) smartctl_device_rotation_rate{{job="smartctl"}}))'
)
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..",
                                    "kubernetes", "apps", "monitoring"))

GREEN = {"color": "green", "value": None}
ANY_RED = [GREEN, {"color": "red", "value": 1}]


def tgt(expr, legend=None, refid="A", table=False):
    t = {"refId": refid, "datasource": DS, "expr": expr}
    if legend is not None:
        t["legendFormat"] = legend
    if table:
        t.update({"instant": True, "range": False, "format": "table"})
    return t


def stat(pid, title, x, y, w, h, expr, unit, steps, description):
    return {
        "id": pid, "type": "stat", "title": title, "description": description,
        "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {
            "unit": unit, "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "value", "graphMode": "none", "textMode": "auto",
                    "justifyMode": "auto"},
        "targets": [tgt(expr)],
    }


def ts(pid, title, x, y, w, h, targets, unit, description, step=False, minv=None):
    custom = {"drawStyle": "line",
              "lineInterpolation": "stepAfter" if step else "smooth",
              "lineWidth": 2, "fillOpacity": 0, "spanNulls": False,
              "showPoints": "never", "pointSize": 5,
              "stacking": {"mode": "none", "group": "A"},
              "axisPlacement": "auto", "axisColorMode": "text",
              "scaleDistribution": {"type": "linear"}}
    defaults = {"unit": unit, "custom": custom, "color": {"mode": "palette-classic"},
                "thresholds": {"mode": "absolute", "steps": [GREEN]}}
    if minv is not None:
        defaults["min"] = minv
    return {
        "id": pid, "type": "timeseries", "title": title, "description": description,
        "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"tooltip": {"mode": "multi", "sort": "desc"},
                    "legend": {"displayMode": "table", "placement": "right",
                               "calcs": ["last", "max"]}},
        "targets": targets,
    }


def col(name, props):
    return {"matcher": {"id": "byName", "options": name}, "properties": props}


panels = []

# --------------------------------------------------------------- headline stats
panels.append(stat(
    1, "Disks reporting", 0, 0, 4, 4,
    f'count(smartctl_device{{{SEL}, device!="", serial_number!=""}}) or vector(0)', "short",
    [GREEN],
    "Disks the exporters are currently returning SMART data for. A disk whose last read "
    "came back empty still appears on the exporter page, but with no serial (or, on "
    "exporter 0.14, no device name), so it is not counted here."))
panels.append(stat(
    2, "SMART FAILED", 4, 0, 4, 4,
    f'count(smartctl_device_smart_status{{{SEL}}} == 0) or vector(0)', "short", ANY_RED,
    "Disks whose own overall-health verdict is FAILED. This is the LATE signal: a disk "
    "can throw uncorrectable errors for weeks while still saying PASSED."))
panels.append(stat(
    3, "Errors rose (24h)", 8, 0, 4, 4,
    f'count(count by (host, device) (({ERR} - min_over_time({ERR}[24h])) > 0)) or vector(0)',
    "short", ANY_RED,
    "Disks with any error counter (realloc, runtime bad block, uncorrectable, pending, "
    "offline uncorrectable, NVMe media errors, SCSI defects) higher than its 24h low. "
    "Same condition as the SmartDiskErrorsIncreased alert."))
panels.append(stat(
    4, "Disks with any errors", 12, 0, 4, 4,
    f'count(count by (host, device) ({ERR} > 0)) or vector(0)', "short",
    [GREEN, {"color": "yellow", "value": 1}],
    "Disks with a non-zero error counter at all, rising or not. Old, stable counts "
    "do not alert; this keeps them visible."))
panels.append(stat(
    5, "Exporters down", 16, 0, 4, 4,
    f'count(up{{{SEL}}} == 0) or vector(0)', "short", ANY_RED,
    "smartctl_exporter targets Prometheus cannot scrape. Disk alerts for those hosts "
    "are blind."))
panels.append(stat(
    6, "Hottest disk", 20, 0, 4, 4, f'max({TEMP})', "celsius",
    [GREEN, {"color": "yellow", "value": 50}, {"color": "red", "value": 60}],
    "Highest current drive temperature across the selected hosts."))

# --------------------------------------------------------------- per-disk table
COUNTERS = [
    (r, c, COUNTER_NAMES[c]) for r, c in [
        ("B", "ata_5"), ("C", "ata_183"), ("D", "ata_187"), ("E", "ata_197"),
        ("F", "ata_198"), ("G", "nvme_media_errors"), ("H", "scsi_grown_defects"),
    ]
]
table_targets = [
    tgt(f'max by (host, device, model_name, serial_number) (smartctl_device{{{SEL}}})',
        refid="A", table=True),
    tgt('max by (host, device, disk) (smartctl:device_display_info{host=~"$host"})',
        refid="N", table=True),
]
table_targets += [
    tgt('max by (host, device) (' + err('counter="' + c + '"') + ')', refid=r, table=True)
    for r, c, _ in COUNTERS
]
table_targets += [
    tgt('sum by (host, device) (' + err('counter=~"scsi_(read|write)_uncorrected"') + ')',
        refid="I", table=True),
    tgt(f'max by (host, device) (smartctl_device_smart_status{{{SEL}}})', refid="J", table=True),
    tgt(f'max by (host, device) ({TEMP})', refid="K", table=True),
    tgt(WEAR, refid="L", table=True),
    tgt(f'max by (host, device) (smartctl_device_power_on_seconds{{{SEL}}})', refid="M",
        table=True),
]
rename = {"host": "Host", "disk": "Disk", "device": "Device", "model_name": "Model",
          "serial_number": "Serial", "Value #I": "SCSI uncorrected",
          "Value #J": "SMART", "Value #K": "Temp", "Value #L": "Wear used",
          "Value #M": "Power-on"}
rename.update({f"Value #{r}": name for r, _, name in COUNTERS})
error_cols = [name for _, _, name in COUNTERS] + ["SCSI uncorrected"]

overrides = [col(name, [
    {"id": "unit", "value": "short"},
    {"id": "thresholds", "value": {"mode": "absolute", "steps": ANY_RED}},
    {"id": "custom.cellOptions", "value": {"type": "color-text"}},
]) for name in error_cols]
overrides += [
    col("SMART", [
        {"id": "mappings", "value": [{"type": "value", "options": {
            "1": {"text": "PASSED", "color": "green", "index": 0},
            "0": {"text": "FAILED", "color": "red", "index": 1}}}]},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
    ]),
    col("Temp", [
        {"id": "unit", "value": "celsius"},
        {"id": "thresholds", "value": {"mode": "absolute", "steps": [
            GREEN, {"color": "yellow", "value": 50}, {"color": "red", "value": 60}]}},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
    ]),
    col("Wear used", [
        {"id": "unit", "value": "percent"},
        {"id": "decimals", "value": 0},
        {"id": "thresholds", "value": {"mode": "absolute", "steps": [
            GREEN, {"color": "yellow", "value": 80}, {"color": "red", "value": 90}]}},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
    ]),
    col("Power-on", [{"id": "unit", "value": "s"}, {"id": "decimals", "value": 1}]),
]
panels.append({
    "id": 7, "type": "table", "title": "Disks",
    "description": (
        "One row per disk. Disk is the short name used in the charts: osd.N · sdX for "
        "Ceph OSDs, otherwise the device name. Device is the exporter's full name (by-id "
        "on the R630s). Error columns are RAW counts (red when non-zero); a blank "
        "cell means the disk does not report that counter (e.g. NVMe has no ATA "
        "attributes). Wear used is the share of rated endurance consumed: NVMe "
        "percentage_used, SAS endurance indicator, or 100 minus the normalized value "
        "of a SATA SSD's wear attribute (177/202/231/233)."),
    "datasource": DS, "gridPos": {"h": 12, "w": 24, "x": 0, "y": 4},
    "fieldConfig": {"defaults": {"custom": {"align": "auto", "filterable": True,
                                            "cellOptions": {"type": "auto"}}},
                    "overrides": overrides},
    "options": {"showHeader": True, "cellHeight": "sm",
                "sortBy": [{"displayName": "Host", "desc": False}]},
    "targets": table_targets,
    "transformations": [
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {
            "excludeByName": {"Time": True, "Value #A": True, "Value #N": True},
            "renameByName": rename,
            "indexByName": {name: i for i, name in enumerate(
                ["host", "disk", "device", "model_name", "serial_number", "Value #J", "Value #K",
                 "Value #L", "Value #M"]
                + [f"Value #{r}" for r, _, _ in COUNTERS] + ["Value #I"])},
        }},
    ],
})

# --------------------------------------------------------------- time series
panels.append(ts(
    8, "Error counters (non-zero only)", 0, 16, 12, 9,
    [tgt(with_disk(named(f'{ERR} > 0')), "{{host}} · {{disk}} · {{counter_name}}")], "short",
    "Raw error counters over time, from the smartctl:device_error_count recording rule. "
    "Disks with all-zero counters are left out. A step up is what the alerts fire on.",
    step=True, minv=0))
panels.append(ts(
    9, "Error counter rise vs 24h low", 12, 16, 12, 9,
    [tgt(with_disk(named(f'({ERR} - min_over_time({ERR}[24h])) > 0')),
         "{{host}} · {{disk}} · {{counter_name}}")],
    "short",
    "How far each counter is above its lowest value in the previous 24h. Anything "
    "here is SmartDiskErrorsIncreased firing; 10+, or 3+ separate steps, is "
    "SmartDiskErrorsGrowing.", step=True, minv=0))
panels.append(ts(
    10, "Temperature", 0, 25, 12, 9,
    [tgt(with_disk(TEMP), "{{host}} · {{disk}}")], "celsius",
    "Current drive temperature as reported by each disk."))
panels.append(ts(
    11, "Wear used", 12, 25, 12, 9,
    [tgt(with_disk(WEAR), "{{host}} · {{disk}}")], "percent",
    "Share of rated endurance used (SSDs only). See the Disks table description for "
    "how it is derived per interface.", minv=0))

dash = {
    "annotations": {"list": []}, "editable": True, "graphTooltip": 1,
    "schemaVersion": 39, "version": 1, "uid": "smart-disks", "title": "Disks / SMART",
    "tags": ["smart", "disks", "proxmox", "truenas"],
    "time": {"from": "now-24h", "to": "now"}, "refresh": "1m",
    "templating": {"list": [DATASOURCE_VAR, HOST_VAR]}, "panels": panels,
}

body = "\n".join("    " + ln for ln in json.dumps(dash, indent=2).splitlines())
doc = (
    "---\n"
    "# Auto-provisioned Grafana dashboard for disk SMART health on the Proxmox hosts and\n"
    "# TrueNAS (job=smartctl). Imported by the kube-prometheus-stack Grafana sidecar via\n"
    "# the grafana_dashboard label. Generated from scripts/monitoring/gen_smart_dashboard.py\n"
    "# — edit the generator, not this file, or the next run silently reverts you.\n"
    "#\n"
    "# $datasource defaults to the local Prometheus (~2d retention) and can be switched\n"
    "# to Thanos in the picker for long-range history.\n"
    "apiVersion: v1\n"
    "kind: ConfigMap\n"
    "metadata:\n"
    "  name: smart-dashboard\n"
    "  namespace: monitoring\n"
    "  labels:\n"
    "    grafana_dashboard: \"1\"\n"
    "data:\n"
    "  smart.json: |\n"
    f"{body}\n"
)
path = os.path.join(REPO, "smart", "dashboard.yaml")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    f.write(doc)
print("wrote", path, f"({len(doc)} bytes)")
