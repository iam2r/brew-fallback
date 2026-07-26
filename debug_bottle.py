#!/usr/bin/env python3
"""Debug: dump brew bottle files structure to understand detection failure."""
import json, os, platform

try:
    data = json.loads(os.popen("brew info autoconf --json=v2 2>/dev/null").read())
    d = data["formulae"][0]
    f = d.get("bottle", {}).get("files", {})
    print("KEYS:", list(f.keys()))
except Exception as e:
    print(f"brew parse error: {e}")

print("ARCH:", platform.machine())
print("DARWIN:", platform.release())
