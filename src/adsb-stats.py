#!/usr/bin/env python3
#
# adsb-stats.py — readsb's statistics, on a web page.
#
#   python3 -I adsb-stats.py [--port 8084] [--dir /run/readsb]
#
# readsb writes its JSON to /run/readsb, which is RAM, because adsb_render
# asks it to in JSON_OPTIONS. Nothing touches the card. This serves those
# files, and nothing else:
#
#   /                   a page that shows them
#   /data/stats.json    message rates, signal levels, range
#   /data/receiver.json what readsb says about itself
#   /data/aircraft.json what it is hearing right now
#
# Everything else is a 404, in the same spirit as the decoder's own status
# pages: a fixed set of paths, never a directory listing. Standard library
# only, because nothing else is installed on the image.
#
# Run by ogn-adsb-web.service, which goes up and down with readsb.
#
# Copyright (c) 2026 ifly7charlie. MIT licence, see LICENSE.

import argparse
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_FILES = ("stats.json", "receiver.json", "aircraft.json")

PAGE = b"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ADS-B statistics</title>
<style>
  :root { --bg:#fff; --fg:#1d1d1f; --mute:#6e6e73; --line:#d2d2d7; --bad:#b00020; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#161617; --fg:#f5f5f7; --mute:#a1a1a6; --line:#3a3a3c; --bad:#ff6b6b; }
  }
  body { background:var(--bg); color:var(--fg); margin:0 auto; max-width:60rem;
         padding:1rem; font:15px/1.4 system-ui, sans-serif; }
  h1 { font-size:1.3rem; margin:0 0 .2rem; }
  h2 { font-size:1rem; margin:1.5rem 0 .4rem; }
  .mute { color:var(--mute); }
  .bad { color:var(--bad); }
  .scroll { overflow-x:auto; }
  table { border-collapse:collapse; width:100%; font-variant-numeric:tabular-nums; }
  th, td { text-align:right; padding:.25rem .6rem; border-bottom:1px solid var(--line);
           white-space:nowrap; }
  th:first-child, td:first-child { text-align:left; }
  th { font-weight:600; }
  a { color:inherit; }
</style>
</head>
<body>
<h1>ADS-B statistics</h1>
<div id="status" class="mute">Loading&hellip;</div>

<h2>Now</h2>
<div class="scroll"><table id="now"></table></div>

<h2>By period</h2>
<div class="scroll"><table id="periods"></table></div>

<p class="mute">Raw data:
  <a href="data/stats.json">stats.json</a> &middot;
  <a href="data/receiver.json">receiver.json</a> &middot;
  <a href="data/aircraft.json">aircraft.json</a>.
  Refreshes every 10&nbsp;s.</p>

<script>
"use strict";
const PERIODS = [["last1min", "Last minute"], ["last5min", "Last 5 min"],
                 ["last15min", "Last 15 min"], ["total", "Since start"]];

function dash(v) { return (v === undefined || v === null || Number.isNaN(v)) ? "\\u2014" : v; }
function num(v, d) { return typeof v === "number" ? v.toFixed(d || 0) : dash(v); }
function sum(a) { return Array.isArray(a) ? a.reduce((x, y) => x + y, 0) : a; }
function km(m) { return typeof m === "number" ? (m / 1000).toFixed(1) + " km" : dash(m); }
function dur(s) {
  if (typeof s !== "number" || s < 0) return dash();
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  return (d ? d + "d " : "") + (d || h ? h + "h " : "") + m + "m";
}

function row(cells, tag) {
  const tr = document.createElement("tr");
  for (const c of cells) {
    const el = document.createElement(tag || "td");
    el.textContent = c;
    tr.appendChild(el);
  }
  return tr;
}

function render(st, ac) {
  const now = document.getElementById("now");
  now.replaceChildren();
  const withPos = st.aircraft_with_pos, without = st.aircraft_without_pos;
  const total = (typeof withPos === "number" && typeof without === "number") ? withPos + without
              : (ac && Array.isArray(ac.aircraft) ? ac.aircraft.length : undefined);
  now.appendChild(row(["Aircraft", dash(total)]));
  now.appendChild(row(["\\u2026 with a position", dash(withPos)]));
  now.appendChild(row(["\\u2026 without", dash(without)]));
  if (ac && typeof ac.messages === "number")
    now.appendChild(row(["Messages since start", ac.messages]));
  if (st.total && typeof st.total.start === "number" && typeof st.now === "number")
    now.appendChild(row(["readsb up for", dur(st.now - st.total.start)]));

  const t = document.getElementById("periods");
  t.replaceChildren();
  t.appendChild(row(["", "Messages/s", "Signal dBFS", "Noise dBFS", "Peak dBFS",
                     "Strong (>-3)", "Max range", "Positions"], "th"));
  for (const [key, label] of PERIODS) {
    const p = st[key];
    if (!p) continue;
    const secs = (p.end - p.start) || NaN;
    const local = p.local || {};
    const msgs = typeof p.messages_valid === "number" ? p.messages_valid : p.messages;
    t.appendChild(row([label,
      num(msgs / secs, 1),
      num(local.signal, 1), num(local.noise, 1), num(local.peak_signal, 1),
      dash(local.strong_signals),
      km(p.max_distance),
      dash(p.position_count_total !== undefined ? p.position_count_total
                                                : (p.cpr && sum(p.cpr.global_ok)))]));
  }
}

async function get(name) {
  const r = await fetch("data/" + name, {cache: "no-store"});
  if (!r.ok) throw new Error(name + ": HTTP " + r.status);
  return r.json();
}

async function refresh() {
  const status = document.getElementById("status");
  try {
    const st = await get("stats.json");
    let ac = null;
    try { ac = await get("aircraft.json"); } catch (e) { /* the table copes */ }
    render(st, ac);
    status.className = "mute";
    status.textContent = "Updated " + new Date().toLocaleTimeString() + ".";
  } catch (e) {
    status.className = "bad";
    status.textContent = "No statistics from readsb yet (" + e.message +
      "). It writes the first set a minute after it starts; if this persists, " +
      "run: sudo ogn-adsb status";
  }
}
refresh();
setInterval(refresh, 10000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "ogn-adsb-stats"
    sys_version = ""
    data_dir = "/run/readsb"

    def _send(self, code, body, ctype, head_only):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _serve(self, head_only):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            return self._send(200, PAGE, "text/html; charset=utf-8", head_only)
        if path.startswith("/data/") and path[6:] in DATA_FILES:
            try:
                with open(os.path.join(self.data_dir, path[6:]), "rb") as f:
                    body = f.read()
            except OSError:
                return self._send(503, b"readsb has not written this yet\n",
                                  "text/plain; charset=utf-8", head_only)
            return self._send(200, body, "application/json", head_only)
        return self._send(404, b"not found\n", "text/plain; charset=utf-8", head_only)

    def do_GET(self):
        self._serve(False)

    def do_HEAD(self):
        self._serve(True)

    # One line per request would fill the journal for nobody to read.
    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description="Serve readsb's statistics over HTTP.")
    ap.add_argument("--port", type=int, default=8084)
    ap.add_argument("--dir", default="/run/readsb")
    args = ap.parse_args()

    Handler.data_dir = args.dir
    httpd = ThreadingHTTPServer(("", args.port), Handler)
    httpd.daemon_threads = True
    # The bound port, not the asked-for one: --port 0 is how the tests get a
    # free port, and they read it from here.
    print(f"serving {args.dir} on port {httpd.server_port}", file=sys.stderr, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
