#!/usr/bin/env python3
"""Insert the CoreDNS `log` plugin into the coredns ConfigMap's Corefile.

Usage: add_log_plugin.py <input-configmap.json> <output-configmap.json>

Idempotent: if `log` is already present as a directive line, the file is
copied through unchanged.
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <in.json> <out.json>", file=sys.stderr)
        sys.exit(1)

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path) as f:
        cm = json.load(f)

    corefile = cm["data"]["Corefile"]
    lines = corefile.splitlines()
    if any(line.strip() == "log" for line in lines):
        print("log plugin already present, no change")
    else:
        # Insert right after the `errors` directive line (present in the
        # default kind/CoreDNS Corefile).
        out_lines = []
        inserted = False
        for line in lines:
            out_lines.append(line)
            if not inserted and line.strip() == "errors":
                indent = line[: len(line) - len(line.lstrip())]
                out_lines.append(f"{indent}log")
                inserted = True
        if not inserted:
            raise SystemExit("could not find 'errors' directive to anchor the insert")
        cm["data"]["Corefile"] = "\n".join(out_lines) + "\n"

    with open(out_path, "w") as f:
        json.dump(cm, f)


if __name__ == "__main__":
    main()
