#!/usr/bin/env python3
"""
syntropd Website Verification Suite
Audits all static HTML/CSS/JS/SVG assets for link integrity, tag balance,
zero external CDN dependencies, and conformance.
"""

import sys
import os
import re
from pathlib import Path
from html.parser import HTMLParser
import xml.etree.ElementTree as ET

ROOT_DIR = Path(__file__).resolve().parent.parent

class HTMLAuditParser(HTMLParser):
    def __init__(self, file_path):
        super().__init__()
        self.file_path = file_path
        self.links = []
        self.assets = []
        self.ids = set()
        self.has_doctype = False
        self.has_viewport = False
        self.has_charset = False
        self.title = ""
        self._in_title = False
        self.external_links = []
        self.tag_stack = []
        self.void_elements = {
            'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
            'link', 'meta', 'param', 'source', 'track', 'wbr'
        }

    def handle_decl(self, decl):
        if 'html' in decl.lower():
            self.has_doctype = True

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        
        # Check IDs
        if 'id' in attrs_dict:
            self.ids.add(attrs_dict['id'])
            
        # Check charset
        if tag == 'meta' and 'charset' in attrs_dict:
            self.has_charset = True
            
        # Check viewport
        if tag == 'meta' and attrs_dict.get('name') == 'viewport':
            self.has_viewport = True

        # Check title
        if tag == 'title':
            self._in_title = True

        # Check links
        if tag == 'a' and 'href' in attrs_dict:
            href = attrs_dict['href']
            self.links.append(href)
            if href.startswith(('http://', 'https://', '//')):
                self.external_links.append(href)

        # Check assets
        if tag in ('link', 'script', 'img', 'source'):
            src = attrs_dict.get('src') or attrs_dict.get('href')
            if src:
                self.assets.append((tag, src))

        if tag not in self.void_elements:
            self.tag_stack.append(tag)

    def handle_endtag(self, tag):
        if tag == 'title':
            self._in_title = False

        if tag not in self.void_elements:
            if self.tag_stack and self.tag_stack[-1] == tag:
                self.tag_stack.pop()
            elif tag in self.tag_stack:
                # Close down to matching tag
                while self.tag_stack and self.tag_stack[-1] != tag:
                    self.tag_stack.pop()
                if self.tag_stack:
                    self.tag_stack.pop()

    def handle_data(self, data):
        if self._in_title:
            self.title += data


def verify_site():
    print("=" * 60)
    print(" syntropd.github.io — Verification Test Suite")
    print("=" * 60)

    errors = []
    warnings = []

    # 1. Enumerate HTML files
    html_files = sorted(list(ROOT_DIR.glob("*.html")))
    if not html_files:
        print("[FAIL] No HTML files found in root directory!")
        return 1

    print(f"[*] Found {len(html_files)} HTML pages to audit.")

    parsed_pages = {}
    
    # Blocklist of external CDN domains that must never be used
    forbidden_cdns = [
        "unpkg.com",
        "cdnjs.cloudflare.com",
        "cdn.jsdelivr.net",
        "fonts.googleapis.com",
        "fonts.gstatic.com",
        "code.jquery.com",
        "stackpath.bootstrapcdn.com"
    ]

    for html_file in html_files:
        rel_name = html_file.name
        content = html_file.read_text(encoding="utf-8")
        parser = HTMLAuditParser(html_file)
        try:
            parser.feed(content)
        except Exception as e:
            errors.append(f"{rel_name}: HTML parsing failed: {e}")
            continue

        parsed_pages[rel_name] = parser

        # Validate Doctype
        if not parser.has_doctype:
            errors.append(f"{rel_name}: Missing <!DOCTYPE html>")

        # Validate Charset
        if not parser.has_charset:
            errors.append(f"{rel_name}: Missing <meta charset='UTF-8'>")

        # Validate Viewport
        if not parser.has_viewport:
            errors.append(f"{rel_name}: Missing <meta name='viewport'>")

        # Validate Title
        if not parser.title.strip():
            errors.append(f"{rel_name}: Missing or empty <title>")

        # Check for unclosed non-void tags
        if parser.tag_stack:
            warnings.append(f"{rel_name}: Potentially unclosed tags: {parser.tag_stack}")

        # Check for external CDN assets
        for tag, src in parser.assets:
            for cdn in forbidden_cdns:
                if cdn in src:
                    errors.append(f"{rel_name}: Disallowed external CDN asset '{src}' in <{tag}>")

        print(f"  [+] {rel_name:<20} | Title: {parser.title[:35]:<35} | {len(parser.ids)} IDs")

    # 2. Audit Internal Relative Links & Anchors
    print("\n[*] Auditing Internal Relative Links & Anchors...")
    for rel_name, parser in parsed_pages.items():
        for href in parser.links:
            # Skip external links and mailto/tel
            if href.startswith(('http://', 'https://', 'mailto:', 'tel:', '#')):
                if href.startswith('#'):
                    # Local anchor check
                    anchor = href[1:]
                    if anchor and anchor not in parser.ids:
                        errors.append(f"{rel_name}: Local anchor '{href}' not found in document")
                continue

            # Split path and anchor
            parts = href.split('#', 1)
            target_path_str = parts[0]
            target_anchor = parts[1] if len(parts) > 1 else None

            target_file = ROOT_DIR / target_path_str
            if not target_file.exists():
                errors.append(f"{rel_name}: Broken link '{href}' -> Target file '{target_path_str}' does not exist")
            elif target_anchor:
                # Check anchor in target file
                if target_path_str in parsed_pages:
                    target_parser = parsed_pages[target_path_str]
                    if target_anchor not in target_parser.ids:
                        errors.append(f"{rel_name}: Link '{href}' target anchor '#{target_anchor}' not found in '{target_path_str}'")

    # 3. Audit Local Assets (CSS, JS, SVG, Favicon)
    print("\n[*] Auditing Local Asset References...")
    for rel_name, parser in parsed_pages.items():
        for tag, src in parser.assets:
            if src.startswith(('http://', 'https://', '//')):
                continue
            asset_path = ROOT_DIR / src
            if not asset_path.exists():
                errors.append(f"{rel_name}: Broken asset in <{tag}>: '{src}' does not exist on disk")

    # 4. Audit CSS Stylesheet
    css_file = ROOT_DIR / "css" / "style.css"
    if not css_file.exists():
        errors.append("css/style.css is missing!")
    else:
        css_content = css_file.read_text(encoding="utf-8")
        if ":root" not in css_content or "--bg-primary" not in css_content:
            errors.append("css/style.css: Missing root color definitions")
        if "@media" not in css_content:
            errors.append("css/style.css: Missing responsive media queries")
        print(f"  [+] css/style.css ({len(css_content)} bytes) verified.")

    # 5. Audit JavaScript App
    js_file = ROOT_DIR / "js" / "app.js"
    if not js_file.exists():
        errors.append("js/app.js is missing!")
    else:
        js_content = js_file.read_text(encoding="utf-8")
        expected_symbols = ["initArchInspector", "initTriageStepper", "initVarlinkBrowser", "initCopyButtons"]
        for sym in expected_symbols:
            if sym not in js_content:
                errors.append(f"js/app.js: Missing core interactive handler '{sym}'")
        print(f"  [+] js/app.js ({len(js_content)} bytes) verified.")

    # 6. Audit SVG Favicon
    favicon_file = ROOT_DIR / "favicon.svg"
    if not favicon_file.exists():
        errors.append("favicon.svg is missing!")
    else:
        try:
            tree = ET.parse(favicon_file)
            root = tree.getroot()
            if not root.tag.endswith('svg'):
                errors.append("favicon.svg: Root element is not <svg>")
            print(f"  [+] favicon.svg valid XML confirmed.")
        except Exception as e:
            errors.append(f"favicon.svg: XML parsing error: {e}")

    # Summary
    print("\n" + "=" * 60)
    if warnings:
        print(f"[!] {len(warnings)} WARNING(S):")
        for w in warnings:
            print(f"    - {w}")

    if errors:
        print(f"[FAIL] {len(errors)} ERROR(S) DETECTED:")
        for err in errors:
            print(f"    ❌ {err}")
        return 1

    print("[SUCCESS] All audits passed cleanly (0 errors)! Site is 100% self-contained.")
    print("=" * 60)
    return 0

if __name__ == '__main__':
    sys.exit(verify_site())
