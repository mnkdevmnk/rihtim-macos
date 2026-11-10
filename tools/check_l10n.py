#!/usr/bin/env python3
"""Report L("...") keys that are missing from a translation table, and unused entries."""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = root / "Sources" / "Rihtim"
key_re = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
entry_re = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)

keys = {}
for f in sorted(src.glob("*.swift")):
    for m in key_re.finditer(f.read_text()):
        keys.setdefault(m.group(1), f.name)

status = 0
for lang in sys.argv[1:] or ["tr", "de"]:
    table = root / "Resources" / "Localization" / f"{lang}.strings"
    entries = dict(entry_re.findall(table.read_text())) if table.exists() else {}
    missing = [k for k in keys if k not in entries]
    unused = [k for k in entries if k not in keys]
    print(f"{lang}: {len(keys)} keys, {len(missing)} missing, {len(unused)} unused")
    for k in missing:
        print(f"  missing: {k!r}  ({keys[k]})")
    for k in unused:
        print(f"  unused:  {k!r}")
    status |= bool(missing)
sys.exit(status)
