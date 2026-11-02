#!/usr/bin/env python3
"""Updates the dependency tables in THIRD_PARTY.md (server: Rust crates for all platforms and
features; apps: Dart packages the app uses at run time, without development tools) and writes
THIRD_PARTY_LICENSES.txt with the licence texts from the package sources (LICENSE*, COPYING*,
NOTICE*, UNLICENSE). Equal texts appear once, headed by the packages they apply to.
The rest of THIRD_PARTY.md stays as it is. Model: tools/third-party.py of tvjoe.

Web app: the npm run-time packages from clients/web/package.json ("dependencies"; build tools are
devDependencies) only go into THIRD_PARTY_LICENSES.txt; THIRD_PARTY.md names them in its text.

Run in the repository root of a machine with cargo, flutter and the package caches (the build
container):  python3 -I tools/third-party.py
Environment: FLUTTER (default: flutter), PUB_CACHE (default: ~/.pub-cache), DEPS_JSON (a saved
`flutter pub deps --json` instead of running flutter)."""
import hashlib
import json
import os
import re
import subprocess

DOC = "THIRD_PARTY.md"
TEXTS = "THIRD_PARTY_LICENSES.txt"
PREFIXES = ("license", "licence", "copying", "notice", "unlicense", "copyright")
texts = {}  # checksum -> (file name, text, [packages])
without = []


def take(path, name):
    body = open(path, encoding="utf-8", errors="replace").read().replace("\r\n", "\n").strip()
    h = hashlib.sha256(body.encode()).hexdigest()
    texts.setdefault(h, (os.path.basename(path), body, []))[2].append(name)


def licence_files(folder, name, licence):
    files = sorted(f for f in os.listdir(folder) if f.lower().startswith(PREFIXES) and os.path.isfile(os.path.join(folder, f)))
    if not files:
        without.append(f"{name} ({licence})")
    for f in files:
        take(os.path.join(folder, f), name)
    return files


def replace_table(lines, head, rows):
    start = lines.index(head)
    end = start + 2
    while end < len(lines) and lines[end].startswith("|"):
        end += 1
    lines[start + 2:end] = rows


# Server: all Rust crates that are not part of this workspace.
meta = json.loads(subprocess.check_output(["cargo", "metadata", "--format-version", "1", "--locked", "--all-features"], text=True))
crates = sorted((p for p in meta["packages"] if p["source"] is not None), key=lambda p: (p["name"], p["version"]))
rust_rows = sorted({f"| {p['name']} | {p['version']} | {p.get('license') or 'unbekannt'} |" for p in crates})
for p in crates:
    licence_files(os.path.dirname(p["manifest_path"]), f"{p['name']} {p['version']} (Rust)", p.get("license") or "unbekannt")


# Apps: Dart packages reachable from the app's run-time dependencies. pub.dev has no licence
# field, so the licence is read from the text (only the common ones; otherwise "see text").
def spdx(body):
    b = " ".join(body.split())
    if "Apache License" in b and "Version 2.0" in b:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in b:
        return "MIT"
    if "Redistribution and use in source and binary forms" in b:
        return "BSD-3-Clause" if re.search(r"Neither the name|names of its\s+contributors", b) else "BSD-2-Clause"
    if "This is free and unencumbered software released into the public domain" in b:
        return "Unlicense"
    if "Mozilla Public License" in b:
        return "MPL-2.0"
    if "GNU LESSER GENERAL PUBLIC LICENSE" in b.upper():
        return "LGPL"
    return "siehe Text"


app = "clients/app"
flutter = os.environ.get("FLUTTER", "flutter")
cache = os.environ.get("PUB_CACHE", os.path.expanduser("~/.pub-cache"))
if os.environ.get("DEPS_JSON"):  # output of `flutter pub deps --json`, made by the build user
    deps = json.load(open(os.environ["DEPS_JSON"], encoding="utf-8"))
else:
    deps = json.loads(subprocess.check_output([flutter, "pub", "deps", "--json"], cwd=app, text=True))
# `--json` cannot leave out development tools: follow the graph from the app's run-time
# dependencies (development tools that are also needed at run time stay in).
by_name = {p["name"]: p for p in deps["packages"]}
root = next(p for p in deps["packages"] if p["kind"] == "root")
used, todo = set(), [d for d in root["dependencies"] if d not in root.get("devDependencies", [])]
while todo:
    n = todo.pop()
    if n not in used and n in by_name:
        used.add(n)
        todo += by_name[n].get("dependencies", [])
dart_rows = []
for p in sorted((by_name[n] for n in used), key=lambda p: p["name"]):
    if p.get("source") != "hosted":
        continue  # the app itself and the Flutter SDK packages (licence: see the Flutter SDK row in THIRD_PARTY.md)
    folder = os.path.join(cache, "hosted", "pub.dev", f"{p['name']}-{p['version']}")
    name = f"{p['name']} {p['version']} (Dart)"
    files = licence_files(folder, name, "unbekannt") if os.path.isdir(folder) else []
    licence = spdx(open(os.path.join(folder, files[0]), encoding="utf-8", errors="replace").read()) if files else "unbekannt"
    dart_rows.append(f"| {p['name']} | {p['version']} | {licence} |")

# Web app: run-time npm packages (bundled into the pages by Vite).
web = "clients/web"
for n in sorted(json.load(open(os.path.join(web, "package.json"), encoding="utf-8")).get("dependencies", {})):
    folder = os.path.join(web, "node_modules", n)
    pkg = json.load(open(os.path.join(folder, "package.json"), encoding="utf-8"))
    licence_files(folder, f"{n} {pkg['version']} (npm)", pkg.get("license") or "unbekannt")

lines = open(DOC, encoding="utf-8").read().split("\n")
replace_table(lines, "| Crate | Version | Lizenz |", rust_rows)
replace_table(lines, "| Paket | Version | Lizenz |", dart_rows)
open(DOC, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
print(f"{len(rust_rows)} Rust crates, {len(dart_rows)} Dart packages entered")

rule = "=" * 78
out = ["Lizenztexte der Bibliotheken Dritter in audiojoe",
       "Erzeugt mit tools/third-party.py aus den Quellen der Rust-Crates, Dart- und npm-Pakete.",
       "Übersicht mit Lizenzangaben: THIRD_PARTY.md.", ""]
for f, body, packages in sorted(texts.values(), key=lambda t: (t[2][0], t[0])):
    out += [rule, f"{f} – gilt für: {', '.join(packages)}", rule, body, ""]
out += [rule, "SQLite (eingebaut über libsqlite3-sys)", rule,
        "SQLite ist gemeinfrei (Public Domain), siehe https://sqlite.org/copyright.html", ""]
if without:
    out += [rule, "Pakete ohne eigene Lizenzdatei (es gilt der Standardtext der genannten Lizenz, siehe https://spdx.org/licenses/):", rule]
    out += [f"- {o}" for o in without] + [""]
open(TEXTS, "w", encoding="utf-8", newline="\n").write("\n".join(out))
print(f"{len(texts)} distinct licence texts, {len(without)} packages without a licence file -> {TEXTS}")
