"""Generates kubernetes/apps/monitoring/technitium/dashboard.yaml (the "DNS / Technitium"
Grafana dashboard ConfigMap). Edit the panels here, then from the repo root:

    python3 scripts/gen-technitium-dashboard.py
"""
import json, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "kubernetes/apps/monitoring/technitium/dashboard.yaml"
LOKI = {"type": "loki", "uid": "${loki}"}

# Dark-mode categorical slots 1-5 of the dataviz reference palette, in fixed order.
S = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181"]
GOOD, WARN, CRIT = "#0ca30c", "#fab219", "#d03b3b"

# Every query starts here; $client narrows it ("" matches every line).
SEL = '{job="syslog", app="technitium"} |= `clientIp="$client`'
CLIENT = '| regexp `clientIp="(?P<client>[^"]*)"`'
QNAME = '| regexp `qName="(?P<qname>[^"]*)"`'
RTYPE = '| regexp `responseType="(?P<rtype>[^"]*)"`'
BLOCKED = '|= `responseType="Blocked"`'

panels, pid = [], [0]


def nid():
    pid[0] += 1
    return pid[0]


def row(title, y):
    panels.append({"id": nid(), "type": "row", "title": title, "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})


def target(expr, instant=False, legend=None):
    t = {"refId": "A", "datasource": LOKI, "expr": expr, "queryType": "instant" if instant else "range"}
    if instant:
        t["instant"] = True
    if legend:
        t["legendFormat"] = legend
    return t


def stat(title, desc, expr, x, y, unit="short", thresholds=None, decimals=0):
    steps = thresholds or [{"color": "text", "value": None}]
    panels.append({
        "id": nid(), "type": "stat", "title": title, "description": desc, "datasource": LOKI,
        "gridPos": {"h": 4, "w": 4, "x": x, "y": y},
        "targets": [target(expr, instant=True)],
        "fieldConfig": {"defaults": {"unit": unit, "decimals": decimals,
                                     "thresholds": {"mode": "absolute", "steps": steps},
                                     "color": {"mode": "thresholds"},
                                     "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value" if thresholds else "none",
                    "graphMode": "none", "textMode": "value", "justifyMode": "center"},
    })


def fixed(matcher_id, opt, color):
    return {"matcher": {"id": matcher_id, "options": opt},
            "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}}]}


def timeseries(title, desc, expr, legend, x, y, w, overrides, stack=False, unit="reqps"):
    custom = {"lineWidth": 2, "fillOpacity": 0, "showPoints": "never", "spanNulls": True,
              "axisSoftMin": 0, "gradientMode": "none"}
    if stack:
        custom.update({"stacking": {"mode": "normal", "group": "A"}, "fillOpacity": 70, "lineWidth": 1})
    panels.append({
        "id": nid(), "type": "timeseries", "title": title, "description": desc, "datasource": LOKI,
        "gridPos": {"h": 8, "w": w, "x": x, "y": y},
        "targets": [target(expr, legend=legend)],
        "fieldConfig": {"defaults": {"unit": unit, "custom": custom, "color": {"mode": "palette-classic"}},
                        "overrides": overrides},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    })


def top_table(title, desc, expr, label, label_title, x, y, w=8):
    panels.append({
        "id": nid(), "type": "table", "title": title, "description": desc, "datasource": LOKI,
        "gridPos": {"h": 10, "w": w, "x": x, "y": y},
        "targets": [target(expr, instant=True)],
        "transformations": [
            {"id": "labelsToFields", "options": {}},
            {"id": "organize", "options": {
                "excludeByName": {"Time": True},
                "renameByName": {label: label_title, "Value": "Queries"},
                "indexByName": {label: 0, "Value": 1}}},
            {"id": "sortBy", "options": {"sort": [{"field": "Queries", "desc": True}]}},
        ],
        "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": [
            {"matcher": {"id": "byName", "options": "Queries"}, "properties": [
                {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"}},
                {"id": "color", "value": {"mode": "fixed", "fixedColor": S[0]}},
                {"id": "custom.width", "value": 170}]}]},
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
    })


R = "[$__range]"
y = 0
row("Overview", y); y += 1
stat("Queries", "Every DNS query answered by the three members in the selected range.",
     f"sum(count_over_time({SEL} {R}))", 0, y)
stat("Blocked", "Queries answered NXDOMAIN because a block list or Blocked zone matched.",
     f"sum(count_over_time({SEL} {BLOCKED} {R}))", 4, y)
stat("Blocked %", "Blocked as a share of all queries.",
     f"100 * sum(count_over_time({SEL} {BLOCKED} {R})) / sum(count_over_time({SEL} {R}))",
     8, y, unit="percent", decimals=1)
stat("Clients", "Distinct client IPs. Clients behind the DCs (domain members asking a DC) appear as the DC's IP.",
     f"count(sum by (client) (count_over_time({SEL} {CLIENT} {R})))", 12, y)
stat("SERVFAIL", "Queries that failed upstream (SERVFAIL). Any is worth a look: forwarders unreachable, "
     "DNSSEC failures, or a broken zone. The table below names them.",
     f"sum(count_over_time({SEL} |= `rCode=\"ServerFailure\"` {R}))", 16, y,
     thresholds=[{"color": GOOD, "value": None}, {"color": WARN, "value": 1}])
stat("Members logging", "Cluster members that sent a query log in the last 5 minutes. Expect 3. Fewer "
     "means a member is down, idle, or its Log Exporter stopped.",
     'count(sum by (host) (count_over_time({job="syslog", app="technitium"}[5m])))', 20, y,
     thresholds=[{"color": CRIT, "value": None}, {"color": WARN, "value": 2}, {"color": GOOD, "value": 3}])
y += 4

row("Traffic", y); y += 1
timeseries("Queries per member", "Query rate answered by each member. Clients use the VIP first, so the "
           "VIP holder (normally dns-01) carries most of it.",
           f"sum by (host) (rate({SEL} [$__interval]))", "{{host}}", 0, y, 12,
           [fixed("byName", "nb-dns-01", S[0]), fixed("byName", "nb-dns-02", S[1]),
            fixed("byRegexp", "technitium-.*", S[2])])
timeseries("Queries by response type", "How each query was answered: from cache, recursion, an "
           "authoritative/forwarded zone, or blocked.",
           f"sum by (rtype) (rate({SEL} {RTYPE} [$__interval]))", "{{rtype}}", 12, y, 12,
           [fixed("byName", "Cached", S[0]), fixed("byName", "Recursive", S[1]),
            fixed("byName", "Authoritative", S[2]), fixed("byName", "Blocked", S[3]),
            fixed("byRegexp", "^(?!Cached$|Recursive$|Authoritative$|Blocked$).*", S[4])], stack=True)
y += 8

row("Who and what", y); y += 1
top_table("Top clients", "Clients with the most queries.",
          f"topk(15, sum by (client) (count_over_time({SEL} {CLIENT} {R})))", "client", "Client", 0, y)
top_table("Top blocked domains", "Domains blocked most often.",
          f"topk(15, sum by (qname) (count_over_time({SEL} {BLOCKED} {QNAME} {R})))", "qname", "Domain", 8, y)
top_table("Clients with the most blocked queries", "A device suddenly high here is worth a look: adware, "
          "a chatty IoT device, or something infected.",
          f"topk(15, sum by (client) (count_over_time({SEL} {BLOCKED} {CLIENT} {R})))", "client", "Client", 16, y)
y += 10
top_table("Top queried domains", "Most-queried names overall.",
          f"topk(15, sum by (qname) (count_over_time({SEL} {QNAME} {R})))", "qname", "Domain", 0, y)
top_table("NXDOMAIN, not blocked", "Names that don't exist, excluding blocks. Mostly typos and stale config; "
          "random-looking names in bulk can mean malware using generated domains.",
          f"topk(15, sum by (qname) (count_over_time({SEL} |= `rCode=\"NxDomain\"` != `responseType=\"Blocked\"` {QNAME} {R})))",
          "qname", "Domain", 8, y)
top_table("SERVFAIL domains", "Names that failed to resolve upstream.",
          f"topk(15, sum by (qname) (count_over_time({SEL} |= `rCode=\"ServerFailure\"` {QNAME} {R})))",
          "qname", "Domain", 16, y)
y += 10

row("Blocked queries (log)", y); y += 1
panels.append({
    "id": nid(), "type": "logs", "title": "Blocked queries", "datasource": LOKI,
    "description": "Most recent blocked lookups. Set the Client box above to follow one device. To unblock "
                   "a domain, add it under Allowed on the Technitium primary.",
    "gridPos": {"h": 12, "w": 24, "x": 0, "y": y},
    "targets": [target(f'{SEL} {BLOCKED} {CLIENT} {QNAME} | regexp `qType="(?P<qtype>[^"]*)"` '
                       '| line_format "{{.client}}  {{.qname}}  {{.qtype}}  ({{.host}})"')],
    "options": {"showTime": True, "wrapLogMessage": False, "sortOrder": "Descending",
                "enableLogDetails": True, "dedupStrategy": "none"},
})

dash = {
    "annotations": {"list": []}, "editable": True, "graphTooltip": 1, "schemaVersion": 39, "version": 1,
    "id": None, "uid": "technitium-dns", "title": "DNS / Technitium",
    "tags": ["dns", "technitium"], "time": {"from": "now-24h", "to": "now"}, "refresh": "1m",
    "templating": {"list": [
        {"name": "loki", "label": "Logs", "type": "datasource", "query": "loki",
         "current": {"selected": False, "text": "Loki", "value": "loki"}, "hide": 0,
         "includeAll": False, "multi": False, "options": [], "refresh": 1, "regex": "", "skipUrlSync": False},
        {"name": "client", "label": "Client IP (starts with)", "type": "textbox", "query": "",
         "current": {"text": "", "value": ""}, "hide": 0,
         "description": "Filter every panel to client IPs starting with this, e.g. 10.1.20.52 or 10.2.169."},
    ]},
    "panels": panels,
}

# overlap / id sanity
seen = {}
for p in panels:
    g = p["gridPos"]
    for c in ((a, b) for a in range(g["x"], g["x"] + g["w"]) for b in range(g["y"], g["y"] + g["h"])):
        assert c not in seen, (p["id"], seen[c])
        seen[c] = p["id"]
assert len({p["id"] for p in panels}) == len(panels)

body = json.dumps(dash, indent=2)
header = """---
# Grafana dashboard "DNS / Technitium": the Technitium cluster's query logs, shipped by
# its Log Exporter app to alloy-syslog (:1516) and stored in Loki as
# {job="syslog", app="technitium"} for 90 days. Every panel is LogQL over the raw
# lines; fields (clientIp, responseType, rCode, qName, qType) are pulled out with
# `| regexp` at query time, never as stream labels, which would explode cardinality.
# Loki serves at most ~30d per query, so keep the time range under that.
#
# Generated by scripts/gen-technitium-dashboard.py: edit the panels there and rerun it,\n# rather than hand-editing the JSON below.
apiVersion: v1
kind: ConfigMap
metadata:
  name: technitium-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  technitium.json: |
"""
with open(OUT, "w") as f:
    f.write(header + "\n".join("    " + l if l else l for l in body.split("\n")) + "\n")
print("panels:", len(panels))
