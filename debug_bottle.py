#!/usr/bin/env python3
"""Debug: dump full brew bottle structure to understand detection failure."""
import json, os, platform

try:
    raw = os.popen("brew info autoconf --json=v2 2>/dev/null").read()
    data = json.loads(raw)
    d = data["formulae"][0]
    # Dump the full bottle block
    bottle = d.get("bottle", {})
    print("=== full bottle block ===")
    print(json.dumps(bottle, indent=2))
except Exception as e:
    print(f"brew parse error: {e}")

print("ARCH:", platform.machine())
print("DARWIN:", platform.release())
