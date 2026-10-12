#!/usr/bin/env python3
"""Checks that every `services.X.y` (server) and `controllers.X.y` (client)
reference points at a function or field that module actually defines.
Services/controllers talk through untyped registries, so the type checker
cannot see these calls; this audit can."""
import os
import re
import sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def members(path, name):
    src = open(path).read()
    found = set(re.findall(r"^(?:function\s+)?%s\.(\w+)" % name, src, re.M))
    found |= set(re.findall(r"^%s\.(\w+)\s*=" % name, src, re.M))
    return found


def collect(folder):
    defs = {}
    for f in os.listdir(folder):
        if f.endswith(".luau"):
            name = f[: -len(".luau")]
            defs[name] = members(os.path.join(folder, f), name)
    return defs


def audit(defs, registry, scan_root):
    bad = 0
    for dirpath, _, files in os.walk(scan_root):
        for f in files:
            if not f.endswith(".luau"):
                continue
            p = os.path.join(dirpath, f)
            src = open(p).read()
            for m in re.finditer(registry + r"\.(\w+)\.(\w+)", src):
                mod, mem = m.group(1), m.group(2)
                line = src[: m.start()].count("\n") + 1
                if mod not in defs:
                    print(f"{p}:{line}: unknown module {mod}")
                    bad += 1
                elif mem not in defs[mod]:
                    print(f"{p}:{line}: {mod}.{mem} is not defined")
                    bad += 1
    return bad


server = collect(os.path.join(root, "src/server/Services"))
server["Actors"] = members(os.path.join(root, "src/shared/Actors.luau"), "Actors")
client = collect(os.path.join(root, "src/client/Controllers"))
problems = audit(server, "services", os.path.join(root, "src/server"))
problems += audit(client, "controllers", os.path.join(root, "src/client"))
print(f"reference audit: {problems} problem(s)")
sys.exit(1 if problems else 0)
