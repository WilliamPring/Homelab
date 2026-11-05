"""bark-relay — Alertmanager webhook JSON -> Bark POST /push. Stdlib only.

Shipped as a ConfigMap by kustomize's configMapGenerator (kustomization.yaml). The generated name
carries a content hash, so editing this file and syncing restarts the pod with the new code.
"""
import json, os, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BARK = os.environ.get("BARK_URL", "http://bark.monitoring.svc.cluster.local:8080/push")
KEY = os.environ["BARK_DEVICE_KEY"]
LINK = os.environ.get("ALERT_LINK", "https://grafana.williampring.ca/alerting/groups")
LEVEL = {"critical": "timeSensitive", "warning": "active"}
RANK = {"critical": 2, "warning": 1}

def where(labels):
    thing = labels.get("pod") or labels.get("deployment") or labels.get("statefulset") \
        or labels.get("daemonset") or labels.get("persistentvolumeclaim") or labels.get("instance") or ""
    return "/".join(x for x in (labels.get("namespace"), thing) if x)

def message(payload):
    alerts = payload.get("alerts", [])
    firing = [a for a in alerts if a.get("status") == "firing"]
    common = payload.get("commonLabels", {})
    name = common.get("alertname") or (alerts[0]["labels"].get("alertname") if alerts else "alert")
    shown = firing or alerts
    lines = []
    for a in shown[:5]:
        ann = a.get("annotations", {})
        text = ann.get("summary") or ann.get("description") or ann.get("message") or ""
        lines.append(text or where(a.get("labels", {})))
    if len(shown) > 5:
        lines.append(f"+{len(shown) - 5} more")
    if firing:
        sev = max((a["labels"].get("severity", "") for a in firing), key=lambda s: RANK.get(s, 0))
        count = f" ×{len(firing)}" if len(firing) > 1 else ""
        return f"🔴 {name}{count}", "\n".join(lines), LEVEL.get(sev, "active")
    return f"🟢 {name} resolved", "\n".join(lines), "passive"

def push(title, body, level):
    data = json.dumps({"device_key": KEY, "title": title, "body": body, "level": level,
                       "group": "homelab", "url": LINK}).encode()
    req = urllib.request.Request(BARK, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        r.read()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/healthz" else 404)
        self.end_headers()

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            title, body, level = message(json.loads(self.rfile.read(n)))
            push(title, body, level)
            self.log_message("pushed: %s", title)
            self.send_response(200)
        except Exception as e:  # noqa: BLE001 — any failure → 502 → Alertmanager retries
            self.log_error("push failed: %r", e)
            self.send_response(502)
        self.end_headers()

ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
