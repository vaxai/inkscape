#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare baseline (target branch) vs current branch Valgrind JSONL outputs.

Only signatures present in current but absent in baseline are treated as
introduced regressions. This is the primary gate for CI: low noise because
pre-existing leaks on master are ignored.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Set


def load_jsonl(path: Path) -> List[dict]:
    if not path.exists():
        return []
    out = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
    return out


def signatures(records: List[dict]) -> Set[str]:
    return {r.get("signature", "") for r in records if r.get("signature")}


def group_by_sig(records: List[dict]) -> Dict[str, List[dict]]:
    g: Dict[str, List[dict]] = defaultdict(list)
    for r in records:
        sig = r.get("signature") or ""
        if sig:
            g[sig].append(r)
    return g


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--baseline", type=Path, required=True, help="Baseline JSONL (target branch)")
    ap.add_argument("--current", type=Path, required=True, help="Current branch JSONL")
    ap.add_argument("--report-md", type=Path, required=True)
    ap.add_argument("--report-json", type=Path, required=True)
    ap.add_argument("--baseline-label", default="baseline")
    ap.add_argument("--current-label", default="current")
    ap.add_argument(
        "--allow-growth-bytes",
        type=int,
        default=0,
        help="If same signature grows by more than this many bytes, treat as regression",
    )
    args = ap.parse_args(argv)

    base_recs = load_jsonl(args.baseline)
    cur_recs = load_jsonl(args.current)
    base_sigs = signatures(base_recs)
    cur_sigs = signatures(cur_recs)
    base_groups = group_by_sig(base_recs)
    cur_groups = group_by_sig(cur_recs)

    introduced = sorted(cur_sigs - base_sigs)
    fixed = sorted(base_sigs - cur_sigs)

    # Growth on existing signatures (optional strictness)
    grown = []
    if args.allow_growth_bytes >= 0:
        for sig in sorted(cur_sigs & base_sigs):
            b_bytes = sum(r.get("bytes", 0) for r in base_groups[sig])
            c_bytes = sum(r.get("bytes", 0) for r in cur_groups[sig])
            delta = c_bytes - b_bytes
            if delta > args.allow_growth_bytes:
                grown.append({"signature": sig, "baseline_bytes": b_bytes, "current_bytes": c_bytes, "delta": delta})

    regressions = []
    for sig in introduced:
        recs = cur_groups[sig]
        sample = recs[0]
        top = sample.get("stack", [{}])
        top_fun = top[0].get("fun", "(no stack)") if top else "(no stack)"
        regressions.append({
            "signature": sig,
            "kind": sample.get("kind"),
            "bytes": sum(r.get("bytes", 0) for r in recs),
            "blocks": sum(r.get("blocks", 0) for r in recs),
            "tests": sorted({r.get("test", "") for r in recs}),
            "tool": sample.get("tool"),
            "inkscape_owned": any(r.get("inkscape_owned") for r in recs),
            "top_function": top_fun,
            "sample_stack": sample.get("stack", [])[:8],
        })

    result = {
        "baseline_label": args.baseline_label,
        "current_label": args.current_label,
        "baseline_count": len(base_recs),
        "current_count": len(cur_recs),
        "introduced_count": len(introduced),
        "fixed_count": len(fixed),
        "grown_count": len(grown),
        "regressions": regressions,
        "fixed_signatures": fixed,
        "grown": grown,
        "failed": bool(regressions) or bool(grown),
    }

    args.report_json.parent.mkdir(parents=True, exist_ok=True)
    args.report_json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# Memory leak regression report",
        "",
        f"- Baseline (`{args.baseline_label}`): **{len(base_recs)}** actionable records",
        f"- Current (`{args.current_label}`): **{len(cur_recs)}** actionable records",
        f"- **Introduced** signatures: **{len(introduced)}**",
        f"- Fixed signatures: **{len(fixed)}**",
        f"- Grown signatures (delta > {args.allow_growth_bytes} B): **{len(grown)}**",
        "",
    ]
    if not regressions and not grown:
        lines.append("No new definite leaks introduced versus baseline.")
        lines.append("")
    if regressions:
        lines.append("## Introduced leaks (failing)")
        lines.append("")
        for reg in regressions:
            lines.append(
                f"### `{reg['signature']}` — {reg['kind']}, {reg['bytes']} B / {reg['blocks']} blocks"
            )
            lines.append(f"- tests: `{', '.join(reg['tests'])}`")
            lines.append(f"- inkscape_owned: `{reg['inkscape_owned']}`")
            lines.append(f"- top: `{reg['top_function']}`")
            if reg.get("sample_stack"):
                lines.append("- stack:")
                for fr in reg["sample_stack"]:
                    loc = fr.get("loc") or ""
                    lines.append(f"  - `{fr.get('fun')}` ({loc})")
            lines.append("")
    if grown:
        lines.append("## Grown existing signatures")
        lines.append("")
        for g in grown:
            lines.append(
                f"- `{g['signature']}`: {g['baseline_bytes']} B -> {g['current_bytes']} B "
                f"(+{g['delta']} B)"
            )
        lines.append("")

    args.report_md.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(json.dumps({
        "failed": result["failed"],
        "introduced_count": result["introduced_count"],
        "fixed_count": result["fixed_count"],
        "grown_count": result["grown_count"],
    }, sort_keys=True))

    return 1 if result["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
