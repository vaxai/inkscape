#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Parse Valgrind memcheck/helgrind output into normalized leak/error records.

Designed for low noise / high accuracy when diffing branch vs target baseline:
  * Only definite leaks are treated as failures by default
  * Stack frames are normalized (no addresses, stripped build prefixes)
  * Optional filtering to Inkscape source frames (src/)
  * Minimum byte/block thresholds drop tiny one-shot noise
  * Output is stable JSONL + human summary for CI artifacts
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional

# Valgrind text format markers
RE_DEFINITE = re.compile(
    r"^(?P<bytes>[\d,]+) bytes in (?P<blocks>[\d,]+) blocks are definitely lost"
)
RE_INDIRECT = re.compile(
    r"^(?P<bytes>[\d,]+) bytes in (?P<blocks>[\d,]+) blocks are indirectly lost"
)
RE_POSSIBLE = re.compile(
    r"^(?P<bytes>[\d,]+) bytes in (?P<blocks>[\d,]+) blocks are possibly lost"
)
RE_REACHABLE = re.compile(
    r"^(?P<bytes>[\d,]+) bytes in (?P<blocks>[\d,]+) blocks are still reachable"
)
RE_ERROR_SUMMARY = re.compile(
    r"^ERROR SUMMARY:\s+(?P<errors>\d+)\s+errors\s+from\s+(?P<contexts>\d+)\s+contexts"
)
RE_LEAK_SUMMARY_DEFINITE = re.compile(
    r"definitely lost:\s+(?P<bytes>[\d,]+)\s+bytes in\s+(?P<blocks>[\d,]+)\s+blocks"
)
RE_STACK_FRAME = re.compile(
    r"^\s*(?:at|by)\s+0x[0-9A-Fa-f]+:\s+(?P<fun>.+?)(?:\s+\((?P<loc>.+)\))?$"
)
RE_HELGRIND = re.compile(
    r"^==\d+==\s+(?P<title>(?:Possible data race|Lock order|Thread|Helgrind).*)"
)
RE_ADDR = re.compile(r"0x[0-9A-Fa-f]+")
RE_BUILD_PREFIX = re.compile(
    r"(?:/home/[^/]+/|/tmp/|/workspace/|/__w/[^/]+/[^/]+/)?"
    r"(?:inkscape[-_/]?[^/]*/)?(?:build[-_/]?[^/]*/)?"
)

KIND_DEFINITE = "definite"
KIND_INDIRECT = "indirect"
KIND_POSSIBLE = "possible"
KIND_REACHABLE = "reachable"
KIND_HELGRIND = "helgrind"
KIND_OTHER = "other"

ACTIONABLE_KINDS_DEFAULT = {KIND_DEFINITE}


def _to_int(s: str) -> int:
    return int(s.replace(",", ""))


def _normalize_fun(fun: str) -> str:
    fun = RE_ADDR.sub("0xADDR", fun)
    # Collapse template / lambda noise slightly for stability
    fun = re.sub(r"\s+", " ", fun).strip()
    return fun


def _normalize_loc(loc: Optional[str]) -> Optional[str]:
    if not loc:
        return None
    loc = RE_ADDR.sub("0xADDR", loc)
    loc = RE_BUILD_PREFIX.sub("", loc)
    # Keep only filename:line when possible
    m = re.search(r"([^/\s]+\.(?:cpp|c|h|hpp|cc|cxx):\d+)", loc)
    if m:
        return m.group(1)
    return loc.strip()


def _is_inkscape_frame(fun: str, loc: Optional[str]) -> bool:
    blob = f"{fun} {loc or ''}"
    if re.search(r"(^|/)src/", blob):
        return True
    if re.search(r"inkscape|Inkscape|SPObject|SPItem|SPDocument", fun):
        return True
    # Avoid counting only system libs as inkscape-owned
    if re.search(r"\b(libc\.so|libstdc\+\+|libglib|libgtk|libgobject|libgio|libcairo|libfontconfig)\b", blob):
        return False
    return False


@dataclass
class StackFrame:
    fun: str
    loc: Optional[str] = None
    inkscape: bool = False


@dataclass
class LeakRecord:
    kind: str
    bytes: int
    blocks: int
    stack: List[StackFrame] = field(default_factory=list)
    test: str = ""
    tool: str = "memcheck"
    signature: str = ""
    inkscape_owned: bool = False
    title: str = ""

    def compute_signature(self) -> str:
        # Signature is kind + normalized top-of-stack functions (inkscape first, else full)
        frames = self.stack
        ink_frames = [f for f in frames if f.inkscape]
        use = ink_frames[:6] if ink_frames else frames[:6]
        parts = [self.kind]
        for fr in use:
            parts.append(fr.fun)
            if fr.loc:
                # filename only for stability across line shifts within same leak site family
                parts.append(fr.loc.split(":")[0])
        raw = "|".join(parts)
        self.signature = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]
        return self.signature

    def to_public_dict(self) -> dict:
        d = asdict(self)
        return d


class ValgrindParser:
    def __init__(
        self,
        min_bytes: int = 1,
        min_blocks: int = 1,
        inkscape_only: bool = False,
        include_kinds: Optional[set] = None,
    ):
        self.min_bytes = min_bytes
        self.min_blocks = min_blocks
        self.inkscape_only = inkscape_only
        self.include_kinds = include_kinds or ACTIONABLE_KINDS_DEFAULT

    def parse_text(self, text: str, test_name: str = "", tool: str = "memcheck") -> List[LeakRecord]:
        lines = text.splitlines()
        records: List[LeakRecord] = []
        i = 0
        n = len(lines)

        while i < n:
            line = lines[i]
            # Strip leading ==pid== prefix if present
            clean = re.sub(r"^==\d+==\s?", "", line).strip()

            kind = None
            nbytes = nblocks = 0
            title = ""

            m = RE_DEFINITE.match(clean)
            if m:
                kind, nbytes, nblocks = KIND_DEFINITE, _to_int(m.group("bytes")), _to_int(m.group("blocks"))
            else:
                m = RE_INDIRECT.match(clean)
                if m:
                    kind, nbytes, nblocks = KIND_INDIRECT, _to_int(m.group("bytes")), _to_int(m.group("blocks"))
                else:
                    m = RE_POSSIBLE.match(clean)
                    if m:
                        kind, nbytes, nblocks = KIND_POSSIBLE, _to_int(m.group("bytes")), _to_int(m.group("blocks"))
                    else:
                        m = RE_REACHABLE.match(clean)
                        if m:
                            kind, nbytes, nblocks = KIND_REACHABLE, _to_int(m.group("bytes")), _to_int(m.group("blocks"))
                        else:
                            m = RE_HELGRIND.match(line)
                            if m and tool == "helgrind":
                                kind, nbytes, nblocks = KIND_HELGRIND, 0, 1
                                title = m.group("title")

            if kind is None:
                i += 1
                continue

            # Collect following stack frames
            stack: List[StackFrame] = []
            j = i + 1
            while j < n:
                sline = re.sub(r"^==\d+==\s?", "", lines[j]).rstrip()
                if not sline.strip():
                    j += 1
                    # blank line often ends a record in valgrind output
                    if stack:
                        break
                    continue
                sm = RE_STACK_FRAME.match(sline)
                if not sm:
                    # next error / summary
                    if sline.startswith("LEAK SUMMARY") or sline.startswith("ERROR SUMMARY"):
                        break
                    if RE_DEFINITE.match(sline) or RE_INDIRECT.match(sline) or RE_POSSIBLE.match(sline) or RE_REACHABLE.match(sline):
                        break
                    if sline.startswith("at 0x") or sline.startswith("by 0x"):
                        pass
                    else:
                        if stack:
                            break
                if sm:
                    fun = _normalize_fun(sm.group("fun"))
                    loc = _normalize_loc(sm.group("loc"))
                    stack.append(StackFrame(fun=fun, loc=loc, inkscape=_is_inkscape_frame(fun, loc)))
                j += 1

            rec = LeakRecord(
                kind=kind,
                bytes=nbytes,
                blocks=nblocks,
                stack=stack,
                test=test_name,
                tool=tool,
                title=title,
            )
            rec.inkscape_owned = any(f.inkscape for f in stack)
            rec.compute_signature()

            if self._accept(rec):
                records.append(rec)

            i = max(j, i + 1)

        return records

    def _accept(self, rec: LeakRecord) -> bool:
        if rec.kind not in self.include_kinds and rec.kind != KIND_HELGRIND:
            # Always allow helgrind when tool is helgrind via include_kinds override
            if rec.kind != KIND_HELGRIND:
                return False
        if rec.kind == KIND_HELGRIND and KIND_HELGRIND not in self.include_kinds:
            return False
        if rec.kind != KIND_HELGRIND:
            if rec.bytes < self.min_bytes or rec.blocks < self.min_blocks:
                return False
        if self.inkscape_only and rec.kind != KIND_HELGRIND and not rec.inkscape_owned:
            return False
        return True


def summarize(records: List[LeakRecord]) -> dict:
    by_kind: dict = {}
    total_bytes = 0
    for r in records:
        by_kind.setdefault(r.kind, {"count": 0, "bytes": 0, "blocks": 0})
        by_kind[r.kind]["count"] += 1
        by_kind[r.kind]["bytes"] += r.bytes
        by_kind[r.kind]["blocks"] += r.blocks
        total_bytes += r.bytes
    return {
        "total_records": len(records),
        "total_bytes": total_bytes,
        "by_kind": by_kind,
        "signatures": sorted({r.signature for r in records}),
    }


def write_jsonl(records: List[LeakRecord], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r.to_public_dict(), sort_keys=True) + "\n")


def write_summary_md(summary: dict, records: List[LeakRecord], path: Path, title: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"# {title}", "", f"- Total actionable records: **{summary['total_records']}**",
             f"- Total bytes (actionable kinds): **{summary['total_bytes']}**", ""]
    if summary.get("by_kind"):
        lines.append("| Kind | Count | Bytes | Blocks |")
        lines.append("|------|------:|------:|-------:|")
        for kind, stats in sorted(summary["by_kind"].items()):
            lines.append(f"| {kind} | {stats['count']} | {stats['bytes']} | {stats['blocks']} |")
        lines.append("")
    if records:
        lines.append("## Top signatures")
        lines.append("")
        # group by signature
        groups: dict = {}
        for r in records:
            groups.setdefault(r.signature, []).append(r)
        ranked = sorted(groups.items(), key=lambda kv: (-sum(x.bytes for x in kv[1]), -len(kv[1])))
        for sig, recs in ranked[:25]:
            sample = recs[0]
            top_fun = sample.stack[0].fun if sample.stack else "(no stack)"
            lines.append(
                f"- `{sig}` — {sample.kind}, {sum(r.bytes for r in recs)} B in "
                f"{sum(r.blocks for r in recs)} blocks, tests={sorted({r.test for r in recs})}, top=`{top_fun}`"
            )
        lines.append("")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("inputs", nargs="+", help="Valgrind log files (or '-' for stdin)")
    ap.add_argument("--test-name", default="", help="Default test name if not embedded in filename")
    ap.add_argument("--tool", default="memcheck", choices=["memcheck", "helgrind"])
    ap.add_argument("--min-bytes", type=int, default=1)
    ap.add_argument("--min-blocks", type=int, default=1)
    ap.add_argument("--inkscape-only", action="store_true",
                    help="Keep only records with at least one Inkscape stack frame")
    ap.add_argument("--kinds", default="definite",
                    help="Comma-separated kinds: definite,indirect,possible,reachable,helgrind")
    ap.add_argument("--jsonl", type=Path, required=True)
    ap.add_argument("--summary-md", type=Path, default=None)
    ap.add_argument("--title", default="Valgrind summary")
    args = ap.parse_args(argv)

    kinds = {k.strip() for k in args.kinds.split(",") if k.strip()}
    parser = ValgrindParser(
        min_bytes=args.min_bytes,
        min_blocks=args.min_blocks,
        inkscape_only=args.inkscape_only,
        include_kinds=kinds,
    )

    all_records: List[LeakRecord] = []
    for inp in args.inputs:
        if inp == "-":
            text = sys.stdin.read()
            tname = args.test_name or "stdin"
        else:
            p = Path(inp)
            text = p.read_text(encoding="utf-8", errors="replace")
            tname = args.test_name or p.stem
        all_records.extend(parser.parse_text(text, test_name=tname, tool=args.tool))

    summary = summarize(all_records)
    write_jsonl(all_records, args.jsonl)
    if args.summary_md:
        write_summary_md(summary, all_records, args.summary_md, args.title)

    # Machine-readable one-liner for scripts
    print(json.dumps({"ok": True, "summary": summary}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
