#!/usr/bin/env python3
"""Generate the README architecture diagram, one SVG per colour scheme.

Two files rather than one self-switching file: GitHub strips <style> blocks
from inline SVG, so a `prefers-color-scheme` media query inside the document is
silently dropped. The README pairs them with <picture>, which GitHub honours.

A README diagram is studied, not narrated, so it is COMPLETE rather than
minimal: the browser and its static website, Entra External ID, the Function
App's HTTP functions and its Service Bus worker, the queue, the media
storage, Cosmos DB, Azure OpenAI, and the job posting sites the worker
fetches are all on it.
Run:  python3 make_diagram.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))

# ------------------------------------------------------------------------------
# Geometry and style (shared with the other projects' diagrams)
# ------------------------------------------------------------------------------
NW, NH = 420, 110                          # node width, height
GUTTER = 140                               # between columns: room for a label
MARGIN = 40
COL = [MARGIN + i * (NW + GUTTER) for i in range(3)]
ROW = [40 + i * 200 for i in range(4)]
W = MARGIN * 2 + NW * 3 + GUTTER * 2
H = ROW[-1] + NH + 40 + 0
TITLE_PX, SUB_PX, EDGE_PX = 26, 17, 16

THEMES = {
    "dark": {
        "bg": "#0d1117", "panel": "#161b22", "text": "#e6edf3",
        "muted": "#8b949e", "line": "#58a6ff", "local": "#39c5bb",
        "purple": "#c39be8", "navy": "#c8d6e8", "blue": "#58a6ff",
        "amber": "#f2c163", "store": "#7ee787",
    },
    "light": {
        "bg": "#ffffff", "panel": "#f6f8fa", "text": "#1f2328",
        "muted": "#59636e", "line": "#0969da", "local": "#137e77",
        "purple": "#8250df", "navy": "#475467", "blue": "#0969da",
        "amber": "#9a6700", "store": "#1a7f37",
    },
}

# Lucide icon paths, on a 24-unit grid.
ICONS = {
    "globe": ['<circle cx="12" cy="12" r="10"/>',
              '<path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/>',
              '<path d="M2 12h20"/>'],
    "route": ['<circle cx="6" cy="19" r="3"/>', '<circle cx="18" cy="5" r="3"/>',
              '<path d="M12 19h4.5a3.5 3.5 0 0 0 0-7h-8a3.5 3.5 0 0 1 0-7H12"/>'],
    "network": ['<rect x="16" y="16" width="6" height="6" rx="1"/>',
                '<rect x="2" y="16" width="6" height="6" rx="1"/>',
                '<rect x="9" y="2" width="6" height="6" rx="1"/>',
                '<path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"/>',
                '<path d="M12 12V8"/>'],
    "layers": ['<path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83'
               'l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/>',
               '<path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65"/>',
               '<path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"/>'],
    "database": ['<ellipse cx="12" cy="5" rx="9" ry="3"/>',
                 '<path d="M3 5V19A9 3 0 0 0 21 19V5"/>',
                 '<path d="M3 12A9 3 0 0 0 21 12"/>'],
    "key": ['<path d="M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 '
            '1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 '
            '1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z"/>',
            '<circle cx="16.5" cy="7.5" r=".5"/>'],
    "monitor": ['<rect width="20" height="14" x="2" y="3" rx="2"/>',
                '<line x1="8" x2="16" y1="21" y2="21"/>',
                '<line x1="12" x2="12" y1="17" y2="21"/>'],
    "terminal": ['<polyline points="4 17 10 11 4 5"/>',
                 '<line x1="12" x2="20" y1="19" y2="19"/>'],
    "users": ['<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/>',
              '<circle cx="9" cy="7" r="4"/>',
              '<path d="M22 21v-2a4 4 0 0 0-3-3.87"/>',
              '<path d="M16 3.13a4 4 0 0 1 0 7.75"/>'],
    "file": ['<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/>',
             '<path d="M14 2v4a2 2 0 0 0 2 2h4"/>', '<path d="M10 9H8"/>',
             '<path d="M16 13H8"/>', '<path d="M16 17H8"/>'],
}

NODES = {}


def _r(nid):
    """Return (left, top, right, bottom, centre-x, centre-y) for a node."""
    x, y = NODES[nid][0], NODES[nid][1]
    return x, y, x + NW, y + NH, x + NW / 2, y + NH / 2


def gutter_x(c):
    """Centre of the gutter to the right of column c."""
    return COL[c] + NW + GUTTER / 2


def gutter_y(r):
    """Centre of the gap below row r."""
    return ROW[r] + NH + (ROW[1] - ROW[0] - NH) / 2


# ------------------------------------------------------------------------------
# Layout
# ------------------------------------------------------------------------------
# The browser is at the top between its page (left) and Entra External ID
# (right). It calls the Function App below it, which keeps documents in Cosmos
# DB on the right and blobs in media storage on the left. Jobs go through the
# queue under the app to the worker on the left, which reads and writes media
# above it, fetches postings below it, and calls Azure OpenAI along the bottom.
#
# id: (x, y, colour key, icon, title, subtitle[, "dashed"])
NODES.update({
    "browser":  (COL[1], ROW[0], "navy", "globe", "Browser",
                 "vanilla JS SPA"),
    "web":      (COL[0], ROW[0], "store", "layers", "resumeweb<hex>",
                 "storage static website"),
    "entra":    (COL[2], ROW[0], "purple", "users", "Entra External ID",
                 "user flow, SPA app, PKCE"),
    "media":    (COL[0], ROW[1], "store", "layers", "resumemedia<hex>",
                 "blobs: resumes, jobs"),
    "app":      (COL[1], ROW[1], "amber", "route", "Function App",
                 "FC1, HTTP functions, JWT check"),
    "cosmos":   (COL[2], ROW[1], "store", "database", "Cosmos DB",
                 "resume-app: 4 containers, /owner"),
    "worker":   (COL[0], ROW[2], "blue", "terminal", "resume_scoring_worker",
                 "Service Bus trigger, same app"),
    "sb":       (COL[1], ROW[2], "amber", "layers", "resume-scoring-jobs",
                 "Service Bus, 5 min lock, 5 tries"),
    "aoai":     (COL[2], ROW[2], "purple", "layers", "Azure OpenAI",
                 "gpt-4o, GlobalStandard 100K TPM"),
    "sites":    (COL[0], ROW[3], "navy", "globe", "Job posting sites",
                 "fetched over HTTPS"),
})

br, web, en, md = _r("browser"), _r("web"), _r("entra"), _r("media")
app, cos, wk, sb = _r("app"), _r("cosmos"), _r("worker"), _r("sb")
oa, st = _r("aoai"), _r("sites")

# id: (path, colour key, label, label_x, label_y, anchor[, "dashed"])
EDGES = {
    "e_page":   (f"M{br[0]},{br[5]} H{web[2] + 5}", "store",
                 "GET page", gutter_x(0), br[5] - 12, "middle"),
    "e_auth":   (f"M{br[2]},{br[5]} H{en[0] - 5}", "purple",
                 "sign in", gutter_x(1), br[5] - 12, "middle"),
    "e_api":    (f"M{br[4]},{br[3]} V{app[1] - 5}", "line",
                 "Bearer token", br[4] + 14, gutter_y(0) + 6, "start"),
    "e_blob":   (f"M{app[0]},{app[5]} H{md[2] + 5}", "store",
                 "blobs", gutter_x(0), app[5] - 12, "middle"),
    "e_docs":   (f"M{app[2]},{app[5]} H{cos[0] - 5}", "store",
                 "documents", gutter_x(1), app[5] - 12, "middle"),
    "e_send":   (f"M{app[4]},{app[3]} V{sb[1] - 5}", "amber",
                 "send", app[4] + 14, gutter_y(1) + 6, "start"),
    "e_trig":   (f"M{sb[0]},{sb[5]} H{wk[2] + 5}", "amber",
                 "trigger", gutter_x(0), sb[5] - 12, "middle"),
    "e_wblob":  (f"M{wk[4]},{wk[1]} V{md[3] + 5}", "store",
                 "resume, analysis", wk[4] + 14, gutter_y(1) + 6, "start"),
    "e_stat":   (f"M{wk[4] + 140},{wk[1]} V{gutter_y(1) + 15} H{cos[4]} V{cos[3] + 5}",
                 "store", "status, tokens", cos[4] + 14, gutter_y(1) + 6,
                 "start"),
    "e_fetch":  (f"M{wk[4]},{wk[3]} V{st[1] - 5}", "line",
                 "fetch URL", wk[4] + 14, gutter_y(2) + 20, "start"),
    "e_ai":     (f"M{wk[4] + 120},{wk[3]} V{gutter_y(2)} H{oa[4]} V{oa[3] + 5}",
                 "purple", "chat completions", oa[4] + 14, gutter_y(2) + 20,
                 "start"),
}

ALT = ("A browser loads the single-page app from the resumeweb storage static "
       "website and signs in through an Entra External ID user flow. It calls "
       "the Flex Consumption Function App, whose HTTP functions validate the "
       "Entra token and keep resumes, jobs, folders and users in Cosmos DB and "
       "resume text, analyses and attachments in the media storage account. "
       "Submitting a job sends it to the resume-scoring-jobs Service Bus queue. "
       "A queue-triggered worker in the same app fetches the posting, calls "
       "gpt-4o on Azure OpenAI to extract the job and score the resume, and "
       "writes the analysis to storage and the status and token usage to Cosmos "
       "DB. The app reaches every service with its managed identity.")

# ------------------------------------------------------------------------------
# Rendering
# ------------------------------------------------------------------------------
from html import escape

FONT = "-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif"


def node_svg(nid, t):
    """Render one service box: rounded panel, icon, title, subtitle."""
    x, y, key, icon, title, sub, *opt = NODES[nid]
    title, sub = escape(title), escape(sub)
    colour = t[key]
    dash = ' stroke-dasharray="10 7"' if opt and opt[0] == "dashed" else ""
    scale = 1.25
    isz = 24 * scale
    ix, iy = x + 20, y + (NH - isz) / 2
    tx = x + 20 + isz + 14
    return "".join([
        f'<rect x="{x}" y="{y}" width="{NW}" height="{NH}" rx="10" ry="10" '
        f'fill="{t["panel"]}" stroke="{colour}" stroke-width="2"{dash}/>',
        f'<g transform="translate({ix},{iy}) scale({scale})" fill="none" '
        f'stroke="{colour}" stroke-width="2" stroke-linecap="round" '
        f'stroke-linejoin="round">' + "".join(ICONS[icon]) + "</g>",
        f'<text x="{tx}" y="{y + NH/2 - 4}" font-family="{FONT}" '
        f'font-size="{TITLE_PX}" font-weight="600" fill="{t["text"]}">{title}</text>',
        f'<text x="{tx}" y="{y + NH/2 + 22}" font-family="{FONT}" '
        f'font-size="{SUB_PX}" fill="{t["muted"]}">{sub}</text>',
    ])


def edge_svg(eid, t):
    """Render one arrow plus its label (on a background chip, so lines that
    pass behind a label never cut through its text)."""
    d, key, label, lx, ly, anchor, *opt = EDGES[eid]
    label = escape(label)
    colour = t[key]
    dash = ' stroke-dasharray="8 6"' if opt and opt[0] == "dashed" else ""
    out = (f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="2"{dash} '
           f'marker-end="url(#a_{eid})"/>')
    if label:
        out += (f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" '
                f'font-family="{FONT}" font-size="{EDGE_PX}" font-weight="600" '
                f'fill="{colour}" stroke="{t["bg"]}" stroke-width="6" '
                f'paint-order="stroke">{label}</text>')
    return out


def build(t):
    """Assemble the diagram for one theme."""
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}" role="img" aria-label="{ALT}">', "<defs>"]
    # One marker per edge: a shared marker cannot carry per-edge colour.
    for eid, spec in EDGES.items():
        out.append(
            f'<marker id="a_{eid}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="5" markerHeight="5" orient="auto-start-reverse">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{t[spec[1]]}"/></marker>')
    out.append("</defs>")
    out.append(f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>')
    for eid in EDGES:
        out.append(edge_svg(eid, t))
    for nid in NODES:
        out.append(node_svg(nid, t))
    out.append("</svg>")
    return "".join(out)


def main():
    for name, theme in THEMES.items():
        path = os.path.join(HERE, f"architecture-{name}.svg")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(build(theme))
        print(f"  architecture-{name}.svg")


if __name__ == "__main__":
    main()
