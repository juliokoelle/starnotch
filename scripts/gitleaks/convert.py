#!/usr/bin/env python3
"""gitleaks' rules (config/gitleaks.toml, MIT License) as a Swift file for the screen mask.

    scripts/gitleaks/convert.py <gitleaks.toml> [<out.swift>] [--source <release tag>]

Keeps each rule's id, keywords, regex, secret group and entropy, in gitleaks' order. Leaves out a
rule without a regex, a rule tied to a file path (it needs that file's context), the generic rule
(the mask has its own labels and net) and a rule whose regex NSRegularExpression doesn't compile:
`check_regex.swift` asks it, with the Swift toolchain on macOS or Linux. The default output is
Sources/NotchCore/ScreenMaskGitleaks.swift. Needs Python 3.11 (tomllib); never uses the network.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Sources/NotchCore/ScreenMaskGitleaks.swift"
CHECKER = Path(__file__).with_name("check_regex.swift")

# Left out by id, with the reason.
SKIPPED = {"generic-api-key": "the mask has its own labels and net"}

LICENSE = """MIT License

Copyright (c) 2019 Zachary Rice

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""

NAMED_GROUP = re.compile(r"\(\?P<[A-Za-z0-9_]+>")
FLAGS = re.compile(r"\(\?[A-Za-z\-]*[:)]")


def translate(pattern: str, has_secret_group: bool) -> str:
    """Go's RE2 syntax where ICU's differs. A named group `(?P<name>…)` doesn't capture when the
    rule names no secret group (gitleaks would take the first group that matched as the secret, a
    fragment of the key); with one, it stays a plain group so the numbers hold."""
    return escape_hyphens(NAMED_GROUP.sub("(" if has_secret_group else "(?:", pattern))


def escape_hyphens(pattern: str) -> str:
    """A literal hyphen outside a character class written as `\\-`, the same to ICU: a rule's
    literal prefix (Anthropic's `sk-ant-…`) then doesn't read like a key to the export's leak scan or
    a secret scanner. Hyphens in a class or in flags (`(?-i:`) stay."""
    out, i, depth = [], 0, 0
    while i < len(pattern):
        c = pattern[i]
        if c == "\\":
            out.append(pattern[i:i + 2])
            i += 2
            continue
        if depth:
            posix = re.match(r"\[:[a-z]+:\]", pattern[i:]) if c == "[" else None
            if posix:
                out.append(posix.group())
                i += len(posix.group())
                continue
            depth += {"[": 1, "]": -1}.get(c, 0)
            out.append(c)
            i += 1
            continue
        flags = FLAGS.match(pattern, i) if c == "(" else None
        if flags:
            out.append(flags.group())
            i = flags.end()
        elif c == "[":
            # A "]" right after "[" or "[^" is a literal.
            start = re.match(r"\[\^?\]?", pattern[i:]).group()
            out.append(start)
            i += len(start)
            depth = 1
        else:
            out.append("\\-" if c == "-" else c)
            i += 1
    return "".join(out)


def swift_check(patterns: list[str]) -> list[bool]:
    """Whether NSRegularExpression compiles each pattern, from `swift check_regex.swift`."""
    result = subprocess.run(["swift", str(CHECKER)], input=json.dumps(patterns), capture_output=True, text=True, check=True)
    answers = json.loads(result.stdout.strip().splitlines()[-1])
    if len(answers) != len(patterns):
        raise SystemExit("check_regex.swift answered for a different number of patterns")
    return answers


def swift_string(text: str) -> str:
    if any(ord(c) < 0x20 for c in text):
        raise SystemExit(f"control character in {text!r}")
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def swift_raw(text: str) -> str:
    """A raw string literal whose delimiter doesn't occur in the text (`"#` or `\\#` would end or escape it)."""
    if "\n" in text or "\r" in text:
        raise SystemExit("a pattern with a line break")
    hashes = "#"
    while f'"{hashes}' in text or f"\\{hashes}" in text:
        hashes += "#"
    return f'{hashes}"{text}"{hashes}'


def convert(toml_text: str, source: str, check: Callable[[list[str]], list[bool]]) -> tuple[str, dict[str, str]]:
    """The Swift file and the rules left out (id: reason)."""
    rules = tomllib.loads(toml_text).get("rules", [])
    left_out: dict[str, str] = {}
    kept = []
    for rule in rules:
        rid = rule.get("id", "")
        if not rid:
            continue
        if rid in SKIPPED:
            left_out[rid] = SKIPPED[rid]
        elif not rule.get("regex"):
            left_out[rid] = "no regex"
        elif rule.get("path"):
            left_out[rid] = "tied to a file path"
        elif not rule.get("keywords"):
            left_out[rid] = "no keywords to filter on"
        else:
            group = int(rule.get("secretGroup", 0))
            kept.append({"id": rid, "keywords": sorted({k.lower() for k in rule["keywords"]}),
                         "pattern": translate(rule["regex"], group > 0), "group": group, "entropy": float(rule.get("entropy", 0))})
    compiles = check([r["pattern"] for r in kept]) if kept else []
    for rule, ok in zip(kept, compiles):
        if not ok:
            left_out[rule["id"]] = "NSRegularExpression doesn't compile its regex"
    kept = [r for r, ok in zip(kept, compiles) if ok]

    lines = [
        "// Generated by scripts/gitleaks/convert.py from gitleaks' rules (github.com/gitleaks/gitleaks,",
        f"// config/gitleaks.toml, {source}). Don't edit it: .github/workflows/gitleaks-rules.yml makes it",
        "// anew every week and opens a pull request when it changed.",
        f"// {len(kept)} rules. Left out:",
    ]
    lines += [f"//   {rid}: {reason}" for rid, reason in sorted(left_out.items())] or ["//   none"]
    lines += ["//", "// gitleaks is under the MIT License:", "//"]
    lines += [("// " + line).rstrip() for line in LICENSE.splitlines()]
    lines += ["", "extension ScreenMask {", "    static let gitleaksRules: [UpstreamRule] = ["]
    for r in kept:
        parts = [f"id: {swift_string(r['id'])}", "keywords: [" + ", ".join(swift_string(k) for k in r["keywords"]) + "]",
                 f"pattern: {swift_raw(r['pattern'])}"]
        if r["group"]:
            parts.append(f"group: {r['group']}")
        if r["entropy"]:
            parts.append(f"entropy: {r['entropy']:g}")
        lines.append("        .init(" + ", ".join(parts) + "),")
    lines += ["    ]", "}", ""]
    return "\n".join(lines), left_out


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:]]
    source = "unknown version"
    if "--source" in args:
        index = args.index("--source")
        source = args[index + 1]
        del args[index:index + 2]
    if not args:
        print(__doc__)
        return 2
    toml_path = Path(args[0])
    out = Path(args[1]) if len(args) > 1 else OUT
    text, left_out = convert(toml_path.read_text(), source, swift_check)
    out.write_text(text)
    print(f"wrote {out} ({text.count('.init(')} rules, {len(left_out)} left out)")
    for rid, reason in sorted(left_out.items()):
        print(f"  left out {rid}: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
