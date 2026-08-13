#!/usr/bin/env python3
"""Build the gallery from index.json — the same file Puddle browses.

One source for both: the catalog the app reads and the pages people look at cannot drift
apart if neither is written by hand. Output is plain static files for GitHub Pages.

    python3 tools/build-site.py [release-tag]
"""

import html
import json
import shutil
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
INDEX = ROOT / "index.json"
REPO = "https://github.com/gapul/puddle-shaders"

# Wallpapers of mine that live in their own repositories, listed here so there is one page to
# look at rather than one per repository. Their catalogs are fetched, not copied: the entry on
# the page is the entry the app installs, same as for the shaders in this one.
GUESTS = [
    "https://github.com/gapul/puddle-chess/releases/latest/download/index.json",
]

STYLE = """
:root {
    color-scheme: light dark;
    --bg: #faf4ed; --fg: #575279; --muted: #797593; --line: #dfdad9; --card: #fffaf3;
}
@media (prefers-color-scheme: dark) {
    :root { --bg: #191724; --fg: #e0def4; --muted: #908caa; --line: #26233a; --card: #1f1d2e; }
}
* { box-sizing: border-box; }
body {
    margin: 0; padding: 3rem 1.5rem 5rem; background: var(--bg); color: var(--fg);
    font: 16px/1.6 ui-sans-serif, -apple-system, system-ui, sans-serif;
}
main { max-width: 60rem; margin: 0 auto; }
h1 { font-size: 1.6rem; margin: 0 0 .3rem; }
a { color: inherit; }
.lede { color: var(--muted); margin: 0 0 2.5rem; }
.grid { display: grid; gap: 1.5rem; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); }
.card {
    display: block; text-decoration: none; background: var(--card);
    border: 1px solid var(--line); border-radius: .7rem; overflow: hidden;
}
.card img { display: block; width: 100%; aspect-ratio: 16 / 10; object-fit: cover; background: var(--line); }
.card .body { padding: .8rem 1rem 1rem; }
.card .row { display: flex; align-items: center; justify-content: space-between; gap: .5rem; margin-top: .6rem; }
.card .go { font-size: .8rem; color: var(--muted); }
.mini {
    padding: .3rem .7rem; border-radius: .4rem; background: var(--fg); color: var(--bg);
    text-decoration: none; font-size: .8rem; font-weight: 600;
}
.card h2 { font-size: 1rem; margin: 0 0 .2rem; }
.tag {
    vertical-align: .1em; margin-left: .4rem; padding: .1rem .4rem; border-radius: .3rem;
    border: 1px solid var(--line); color: var(--muted); font-size: .65rem; font-weight: 600;
    text-transform: uppercase; letter-spacing: .04em;
}
.card p { margin: 0; font-size: .85rem; color: var(--muted); }
.hero img, .hero video { display: block; width: 100%; border-radius: .7rem; border: 1px solid var(--line); }
.meta { color: var(--muted); font-size: .9rem; }
pre {
    background: var(--card); border: 1px solid var(--line); border-radius: .5rem;
    padding: .8rem 1rem; overflow-x: auto; font-size: .85rem;
}
.back { display: inline-block; margin-bottom: 1.5rem; color: var(--muted); text-decoration: none; }
.install {
    display: inline-block; margin: .2rem 0 .8rem; padding: .6rem 1.2rem; border-radius: .5rem;
    background: var(--fg); color: var(--bg); text-decoration: none; font-weight: 600;
}
.install:hover { opacity: .85; }
.aside { margin-top: .2rem; }
"""


def hero(entry):
    """The moving one where there is one — these wallpapers are motion, and a still frame of a
    drifting field says very little. The grid stays on still images so a page of nine does not
    fetch nine videos."""
    if animation := entry.get("animation"):
        return (
            f'<video src="{html.escape(animation)}" poster="{html.escape(entry["preview"])}"'
            ' autoplay loop muted playsinline></video>'
        )

    return f'<img src="{html.escape(entry["preview"])}" alt="">'


def page(title, body):
    return f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{STYLE}</style>
<main>
{body}
</main>
"""


def guests():
    """The entries from the other catalogs, tagged with where they came from."""
    found = []

    for url in GUESTS:
        with urllib.request.urlopen(url, timeout=30) as response:
            catalog = json.load(response)

        for entry in catalog["wallpapers"]:
            # `https://github.com/owner/name/releases/…` — the repository the asset is published
            # from, which is the repository to send people to.
            found.append(entry | {"repo": "/".join(entry["url"].split("/")[:5])})

    return found


def source(entry):
    return entry.get("repo", REPO)


def note(entry):
    """What a plugin needs that a shader does not."""
    if entry.get("kind") != "plugin":
        return ""

    return f"""<p class="meta aside">This one is a plugin — native code, loaded into Puddle —
so Puddle installs it only from a source named in <code>~/.config/puddle/install.toml</code>:</p>
<pre>allow = [
    "{html.escape(source(entry))}/releases/",
]</pre>"""


def main():
    index = json.loads(INDEX.read_text())
    entries = index["wallpapers"] + guests()

    if SITE.exists():
        shutil.rmtree(SITE)
    (SITE / "w").mkdir(parents=True)

    cards = "\n".join(
        f"""<div class="card">
    <a href="w/{e['id']}.html"><img src="{html.escape(e['preview'])}" alt="" loading="lazy"></a>
    <div class="body">
        <h2>{html.escape(e['name'])}{' <span class="tag">plugin</span>' if e.get('kind') == 'plugin' else ''}</h2>
        <p>{html.escape(e.get('description', ''))}</p>
        <div class="row">
            <a class="go" href="w/{e['id']}.html">Details →</a>
            <a class="mini" href="puddle:install?url={urllib.parse.quote(e['url'], safe='')}">Install</a>
        </div>
    </div>
</div>"""
        for e in entries
    )

    (SITE / "index.html").write_text(page(
        index["name"],
        f"""<h1>{html.escape(index['name'])}</h1>
<p class="lede">Metal wallpapers for <a href="https://github.com/gapul/Puddle">Puddle</a>, and the
plugins that keep them company. Install them from the app's catalog, or one at a time from a
terminal.</p>
<div class="grid">
{cards}
</div>""",
    ))

    for entry in entries:
        install = f"puddle install {entry['id']}"
        (SITE / "w" / f"{entry['id']}.html").write_text(page(
            f"{entry['name']} — {index['name']}",
            f"""<a class="back" href="../">← all wallpapers</a>
<div class="hero">{hero(entry)}</div>
<h1>{html.escape(entry['name'])}</h1>
<p class="meta">by {html.escape(entry.get('author', 'unknown'))}</p>
<p>{html.escape(entry.get('description', ''))}</p>
<h2>Install</h2>
<a class="install" href="puddle:install?url={urllib.parse.quote(entry['url'], safe='')}">Install in Puddle</a>
<p class="meta aside">Hands it to Puddle, which asks before downloading. The address is
passed straight through, so this works whether or not you have this catalog configured.</p>
{note(entry)}
<p class="meta">From a terminal instead:</p>
<pre>{html.escape(install)}</pre>
<p class="meta">Or in Puddle: <b>Wallpapers → Browse</b>. The asset is
<a href="{html.escape(entry['url'])}">{html.escape(entry['url'].rsplit('/', 1)[-1])}</a>,
and the source is on <a href="{html.escape(source(entry))}">GitHub</a>.</p>""",
        ))

    print(f"built {len(entries) + 1} pages into {SITE.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
