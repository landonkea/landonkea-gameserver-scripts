#!/usr/bin/env python3
"""
control-panel.py -- minimal, standard-library-only HTTP server that adds a
read-write web control panel on top of this platform's existing read-only
status view.

Routes:
  GET  /                                       HTML dashboard (status table,
                                                 plus start/stop/restart
                                                 buttons IF actions are
                                                 enabled -- see below)
  GET  /api/status                              same data as JSON
  POST /api/instances/<name>/start|stop|restart  perform the action
                                                 (requires a valid token --
                                                 see SECURITY MODEL)

Not exposed by default: this script does nothing on its own. An operator
must explicitly run setup-control-panel.sh --enable to generate a token,
write the config file, and (optionally) install/start the systemd unit
that runs this file. Until that happens, this script -- even if started
by hand -- has no config to read and every action request is refused.

SECURITY MODEL (read this before touching anything below):

  1. Fails CLOSED. Actions require CONTROL_PANEL_ENABLED=1 AND a non-empty
     CONTROL_PANEL_TOKEN to both be present in the config file. If either
     is missing, every action request gets 403 "control panel actions are
     not enabled on this server" -- no exceptions, no partial-enable state.

  2. The token is accepted ONLY via the "Authorization: Bearer <token>"
     request header, compared with hmac.compare_digest (constant-time, so
     response timing can't be used to guess the token one character at a
     time). It is never accepted via a query string, form field, or
     cookie -- a query-string token would get written into this process's
     own request log, any reverse proxy's access log, and browser history,
     none of which are places a live admin credential belongs.

  3. Actions are POST-only; GET/HEAD/PUT/DELETE/... on an action path is
     405. Combined with the header-only token (point 2), this is also
     this server's CSRF defense: an ordinary cross-site <form> submission
     cannot POST with a custom Authorization header (forms only send
     Content-Type: application/x-www-form-urlencoded / multipart/
     text-plain bodies with no custom headers), and a cross-site fetch()
     that tried to attach one would trigger a CORS preflight -- which this
     server never answers with any Access-Control-Allow-* header, so the
     browser blocks the real request before it's ever sent. No CSRF token
     is needed on top of that; the bearer token already serves as one.

  4. Every action attempt -- success or failure, authorized or not -- is
     appended to an audit log (timestamp, client address, instance,
     action, outcome) so "who started/stopped what, and when" is always
     answerable after the fact.

  5. Instance names are checked against a strict allow-list regex AND
     checked for registry membership before ever being handed to a
     subprocess. The actual systemctl work happens only inside
     control-panel-instance-action.sh (a separate, root-only script),
     invoked as an argv list via subprocess.run -- never through a shell
     string -- so there is no path by which request input reaches a shell.

  6. Binds to 127.0.0.1 by default. Reaching it from another machine means
     an operator deliberately either changed CONTROL_PANEL_BIND or set up
     their own reverse proxy/SSH tunnel/VPN in front of it -- this script
     itself doesn't speak TLS and shouldn't be put directly on the public
     internet.
"""
from __future__ import annotations

import argparse
import hmac
import html
import json
import logging
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

INSTANCE_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
VALID_ACTIONS = ("start", "stop", "restart")


def gs_base() -> str:
    return os.environ.get("CONTROL_PANEL_GS_BASE", "/srv/gameservers")


def default_conf_path() -> str:
    return os.path.join(gs_base(), "control-panel.conf")


def default_action_script() -> str:
    return os.path.join(gs_base(), "scripts", "control-panel-instance-action.sh")


def default_audit_log() -> str:
    return os.environ.get(
        "CONTROL_PANEL_AUDIT_LOG", os.path.join(gs_base(), "control-panel-audit.log")
    )


def default_registry() -> str:
    return os.path.join(gs_base(), "instances.registry")


def load_config(conf_path: str) -> dict:
    """Parses the KEY=value (optionally "quoted") config file written by
    setup-control-panel.sh. Missing file or unreadable lines are simply
    treated as "nothing configured" -- this function never raises, because
    a malformed/missing config must always be interpreted as the fail-
    closed default, never as an error that could somehow be bypassed."""
    cfg: dict = {}
    try:
        with open(conf_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                cfg[key] = value
    except OSError:
        return {}
    return cfg


def actions_enabled(cfg: dict) -> bool:
    return cfg.get("CONTROL_PANEL_ENABLED") == "1" and bool(cfg.get("CONTROL_PANEL_TOKEN"))


def read_registry(registry_path: str):
    """Returns a list of (name, game, port) tuples. Empty list if the
    registry doesn't exist yet (fresh install, no instances added)."""
    out = []
    try:
        with open(registry_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                parts = line.split(":")
                if len(parts) < 3:
                    continue
                name, game, port = parts[0], parts[1], parts[2]
                out.append((name, game, port))
    except OSError:
        pass
    return out


def systemctl_is_active(unit: str) -> str:
    try:
        proc = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return proc.stdout.strip() or "unknown"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"


def port_listening(port: str) -> bool:
    try:
        udp = subprocess.run(["ss", "-uln"], capture_output=True, text=True, timeout=10)
        tcp = subprocess.run(["ss", "-tln"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    combined = (udp.stdout or "") + (tcp.stdout or "")
    return bool(re.search(rf":{re.escape(port)}[ \t]", combined))


def build_status(registry_path: str) -> dict:
    instances = []
    running = stopped = 0
    for name, game, port in read_registry(registry_path):
        state = systemctl_is_active(f"gameserver@{name}")
        listening = port_listening(port)
        if state == "active":
            running += 1
        else:
            stopped += 1
        instances.append(
            {
                "name": name,
                "game": game,
                "port": port,
                "status": "running" if state == "active" else "stopped",
                "listening": listening,
            }
        )
    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "instances": instances,
        "summary": {"running": running, "stopped": stopped, "total": len(instances)},
    }


def render_html(status: dict, enabled: bool) -> str:
    rows = []
    for inst in status["instances"]:
        name = html.escape(inst["name"])
        game = html.escape(inst["game"])
        port = html.escape(str(inst["port"]))
        state_cls = "up" if inst["status"] == "running" else "down"
        listening = "yes" if inst["listening"] else "no"
        if enabled:
            buttons = "".join(
                f'<button type="button" class="act" '
                f'data-name="{name}" data-action="{a}">{a}</button>'
                for a in VALID_ACTIONS
            )
        else:
            buttons = '<span class="ro">read-only</span>'
        rows.append(
            f"<tr><td>{name}</td><td>{game}</td>"
            f'<td class="{state_cls}">{inst["status"]}</td>'
            f"<td>{port}</td><td>{listening}</td>"
            f"<td>{buttons}</td></tr>"
        )
    rows_html = "\n".join(rows) or '<tr><td colspan="6">No instances registered.</td></tr>'

    token_bar = ""
    script = ""
    if enabled:
        token_bar = """
<div id="tokenbar">
  <label for="token">Admin token:</label>
  <input type="password" id="token" placeholder="paste token, then click an action" autocomplete="off">
  <label><input type="checkbox" id="remember"> remember for this tab</label>
</div>
"""
        script = """
<script>
(function () {
  var tokenInput = document.getElementById('token');
  var remember = document.getElementById('remember');
  var saved = sessionStorage.getItem('cpToken');
  if (saved) { tokenInput.value = saved; remember.checked = true; }
  remember.addEventListener('change', function () {
    if (!remember.checked) { sessionStorage.removeItem('cpToken'); }
  });
  document.querySelectorAll('button.act').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var name = btn.getAttribute('data-name');
      var action = btn.getAttribute('data-action');
      var token = tokenInput.value.trim();
      if (!token) { alert('Enter the admin token first.'); return; }
      if (remember.checked) { sessionStorage.setItem('cpToken', token); }
      if (!confirm(action + ' instance "' + name + '"?')) { return; }
      btn.disabled = true;
      fetch('/api/instances/' + encodeURIComponent(name) + '/' + encodeURIComponent(action), {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + token }
      }).then(function (resp) {
        return resp.json().then(function (body) { return { ok: resp.ok, body: body }; });
      }).then(function (result) {
        if (!result.ok) { alert('Failed: ' + (result.body.error || 'unknown error')); }
        location.reload();
      }).catch(function (err) {
        alert('Request failed: ' + err);
        btn.disabled = false;
      });
    });
  });
})();
</script>
"""

    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>Game Server Control Panel</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 2rem; background:#111; color:#eee; }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ padding: .5rem .75rem; border-bottom: 1px solid #333; text-align: left; }}
.up {{ color: #4caf50; }} .down {{ color: #f44336; }}
button.act {{ margin-right: .25rem; }}
#tokenbar {{ margin-bottom: 1rem; }}
.ro {{ color: #888; font-style: italic; }}
.note {{ color: #888; font-size: .85rem; }}
</style></head>
<body>
<h1>Game Server Control Panel</h1>
<p class="note">Generated {html.escape(status["generated_at"])} &middot;
{status["summary"]["running"]} running, {status["summary"]["stopped"]} stopped,
{status["summary"]["total"]} total.
{"" if enabled else " Actions are disabled on this server (read-only)."}</p>
{token_bar}
<table>
<tr><th>Instance</th><th>Game</th><th>Status</th><th>Port</th><th>Listening</th><th>Actions</th></tr>
{rows_html}
</table>
{script}
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "GameServerControlPanel/1.0"

    # Silence the default per-request stderr logging in favor of our own
    # audit-focused logging (still available via --verbose through the
    # base class's logging if ever needed for debugging).
    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        logging.getLogger("control-panel.http").debug(fmt, *args)

    # -- shared helpers -----------------------------------------------
    def _send_json(self, code: int, payload: dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, code: int, body_str: str):
        body = body_str.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _bearer_token(self) -> str:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return ""
        return auth[len("Bearer ") :].strip()

    def _audit(self, action: str, name: str, outcome: str, detail: str = ""):
        logging.getLogger("control-panel.audit").info(
            "client=%s action=%s instance=%s outcome=%s%s",
            self.client_address[0] if self.client_address else "?",
            action,
            name,
            outcome,
            f" detail={detail!r}" if detail else "",
        )

    # -- routing --------------------------------------------------------
    def do_GET(self):  # noqa: N802 - stdlib method name
        path = urlsplit(self.path).path
        cfg = load_config(self.server.conf_path)  # type: ignore[attr-defined]
        enabled = actions_enabled(cfg)

        if path == "/":
            status = build_status(self.server.registry_path)  # type: ignore[attr-defined]
            self._send_html(200, render_html(status, enabled))
            return
        if path == "/api/status":
            status = build_status(self.server.registry_path)  # type: ignore[attr-defined]
            self._send_json(200, status)
            return
        if path.startswith("/api/instances/"):
            # GET on an action-shaped path: actions are POST-only.
            self._send_json(405, {"error": "actions require POST, not GET"})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802 - stdlib method name
        path = urlsplit(self.path).path
        m = re.match(r"^/api/instances/([^/]+)/([^/]+)$", path)
        if not m:
            self._send_json(404, {"error": "not found"})
            return

        name, action = m.group(1), m.group(2)

        cfg = load_config(self.server.conf_path)  # type: ignore[attr-defined]
        if not actions_enabled(cfg):
            # Fail closed BEFORE looking at the token at all -- an
            # unconfigured server refuses every action outright, token or
            # no token, so there is no way to "accidentally" have a valid
            # token still work against a host where an operator never
            # opted in.
            self._audit(action, name, "refused-disabled")
            self._send_json(
                403, {"error": "control panel actions are not enabled on this server"}
            )
            return

        token = self._bearer_token()
        expected = cfg.get("CONTROL_PANEL_TOKEN", "")
        if not token or not hmac.compare_digest(token, expected):
            self._audit(action, name, "refused-bad-token")
            self._send_json(401, {"error": "missing or invalid token"})
            return

        if action not in VALID_ACTIONS:
            self._audit(action, name, "refused-bad-action")
            self._send_json(400, {"error": f"action must be one of {VALID_ACTIONS}"})
            return

        if not INSTANCE_NAME_RE.match(name):
            self._audit(action, name, "refused-bad-name")
            self._send_json(400, {"error": "invalid instance name"})
            return

        known = {n for n, _g, _p in read_registry(self.server.registry_path)}  # type: ignore[attr-defined]
        if name not in known:
            self._audit(action, name, "refused-unknown-instance")
            self._send_json(404, {"error": f"no instance named '{name}'"})
            return

        script = self.server.action_script  # type: ignore[attr-defined]
        try:
            proc = subprocess.run(
                [script, action, name],
                capture_output=True,
                text=True,
                timeout=45,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            self._audit(action, name, "error", str(exc))
            self._send_json(500, {"error": f"failed to run action script: {exc}"})
            return

        if proc.returncode == 0:
            self._audit(action, name, "ok")
            self._send_json(
                200,
                {
                    "instance": name,
                    "action": action,
                    "result": "ok",
                    "output": proc.stdout.strip(),
                },
            )
        else:
            self._audit(action, name, "failed", proc.stderr.strip())
            self._send_json(
                500,
                {
                    "instance": name,
                    "action": action,
                    "result": "failed",
                    "output": (proc.stdout + proc.stderr).strip(),
                },
            )


def setup_logging(audit_log_path: str):
    logging.basicConfig(level=logging.WARNING)
    audit_logger = logging.getLogger("control-panel.audit")
    audit_logger.setLevel(logging.INFO)
    audit_logger.propagate = False
    try:
        handler = logging.FileHandler(audit_log_path)
    except OSError:
        handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
    audit_logger.addHandler(handler)


def main():
    parser = argparse.ArgumentParser(description="Game server web control panel")
    parser.add_argument("--conf", default=default_conf_path())
    parser.add_argument("--registry", default=default_registry())
    parser.add_argument("--action-script", default=default_action_script())
    parser.add_argument("--audit-log", default=default_audit_log())
    parser.add_argument("--bind", default=None, help="overrides CONTROL_PANEL_BIND from config")
    parser.add_argument("--port", type=int, default=None, help="overrides CONTROL_PANEL_PORT from config")
    args = parser.parse_args()

    setup_logging(args.audit_log)

    cfg = load_config(args.conf)
    bind = args.bind or cfg.get("CONTROL_PANEL_BIND", "127.0.0.1")
    port = args.port or int(cfg.get("CONTROL_PANEL_PORT", "8642") or "8642")

    if actions_enabled(cfg):
        print(f"control-panel.py: actions ENABLED, listening on {bind}:{port}")
    else:
        print(
            f"control-panel.py: actions DISABLED (not configured) -- "
            f"read-only dashboard only, listening on {bind}:{port}"
        )

    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.conf_path = args.conf  # type: ignore[attr-defined]
    httpd.registry_path = args.registry  # type: ignore[attr-defined]
    httpd.action_script = args.action_script  # type: ignore[attr-defined]
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
