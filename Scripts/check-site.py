#!/usr/bin/env python3
"""Checks the generated site: broken internal links, images without alt text, missing titles,
page weight, external requests, and wording that would not be true of this project."""
import pathlib, re, sys
from html.parser import HTMLParser

SITE = pathlib.Path(__file__).resolve().parent.parent / "site"
BANNED = ["displaybuddy", "setapp", "lemonsqueezy", "gumroad", "as seen in", "10,000", "thousands of", "4.9 star", "9to5mac", "cult of mac"]


class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids, self.imgs_missing_alt, self.title, self.ext, self.in_title = [], set(), 0, "", [], False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a: self.ids.add(a["id"])
        if tag in ("a", "link") and a.get("href"): self.links.append(a["href"])
        if tag in ("script", "img", "iframe") and a.get("src"): self.ext.append(a["src"])
        if tag == "img" and a.get("alt") is None: self.imgs_missing_alt += 1
        if tag == "title": self.in_title = True

    def handle_data(self, d):
        if self.in_title: self.title += d

    def handle_endtag(self, tag):
        if tag == "title": self.in_title = False


errors, count = [], 0
for page in sorted(SITE.rglob("*.html")):
    count += 1
    text = page.read_text(encoding="utf-8")
    p = P(); p.feed(text)
    rel = page.relative_to(SITE)
    if not p.title.strip(): errors.append(f"{rel}: missing <title>")
    if p.imgs_missing_alt: errors.append(f"{rel}: {p.imgs_missing_alt} image(s) without alt text")
    size = len(text.encode())
    if size > 200_000: errors.append(f"{rel}: {size} bytes is over the 200 KB budget")
    for s in p.ext:
        if s.startswith("http"): errors.append(f"{rel}: external resource {s}")
    low = text.lower()
    for b in BANNED:
        if b in low: errors.append(f"{rel}: contains banned phrase '{b}'")
    for href in p.links:
        if href.startswith(("http://", "https://", "mailto:", "#")): continue
        target = href.split("#")[0].split("?")[0]
        if not target: continue
        if not (page.parent / target).resolve().exists(): errors.append(f"{rel}: broken link {href}")

for need in ("sitemap.xml", "robots.txt", "assets/style.css", "assets/icon.svg", "404.html"):
    if not (SITE / need).exists(): errors.append(f"missing {need}")

print(f"Checked {count} pages.")
if errors:
    print("\n".join(errors)); sys.exit(1)
print("No problems found.")
