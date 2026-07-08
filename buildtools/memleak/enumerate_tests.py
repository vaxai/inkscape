#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Enumerate CTest tests and write a valgrind launcher script.

Designed to work across CMake versions:
  * Newer ctest --show-only=json-v1 often omits the "command" field
  * Commands are resolved from CTestTestfile.cmake and BUILD_DIR/bin/<name>
  * Filters are applied in-process so discovery does not depend on ctest -R/-E
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# add_test([=[name]=] "arg1" "arg2" ...)
# also tolerate unquoted / bracket args
RE_ADD_TEST = re.compile(
    r"add_test\(\s*"
    r"(?:\[=\[([^\]]+)\]=\]|\"([^\"]+)\"|([^\s\)]+))"
    r"\s*(.*?)\)\s*$"
)
RE_SET_PROPS = re.compile(
    r"set_tests_properties\(\s*"
    r"(?:\[=\[([^\]]+)\]=\]|\"([^\"]+)\"|([^\s\)]+))"
    r"\s+PROPERTIES\s+(.*)\)\s*$"
)
RE_TOKEN = re.compile(
    r"\"([^\"]*)\""
    r"|\[=\[(.*?)\]=\]"
    r"|(\S+)"
)
RE_PROP_ENV = re.compile(r'\bENVIRONMENT\s+"([^"]*)"')
RE_PROP_ENV_UNQUOTED = re.compile(r"\bENVIRONMENT\s+(\S+)")
RE_PROP_WD = re.compile(r'\bWORKING_DIRECTORY\s+"([^"]*)"')
RE_PROP_WD_UNQUOTED = re.compile(r"\bWORKING_DIRECTORY\s+(\S+)")


def tokenize_args(blob: str) -> List[str]:
    out: List[str] = []
    for m in RE_TOKEN.finditer(blob.strip()):
        tok = m.group(1) if m.group(1) is not None else (
            m.group(2) if m.group(2) is not None else m.group(3)
        )
        if tok is not None and tok != "":
            out.append(tok)
    return out


def parse_ctest_files(build_dir: Path) -> Dict[str, dict]:
    """Return name -> {cmd, env, workdir} from generated CTestTestfile.cmake files."""
    tests: Dict[str, dict] = {}
    for tf in build_dir.rglob("CTestTestfile.cmake"):
        try:
            text = tf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            s = line.strip()
            if s.startswith("add_test("):
                m = RE_ADD_TEST.match(s)
                if not m:
                    continue
                name = m.group(1) or m.group(2) or m.group(3)
                args = tokenize_args(m.group(4) or "")
                if not name or not args:
                    continue
                entry = tests.setdefault(name, {"cmd": None, "env": [], "workdir": None})
                entry["cmd"] = args
            elif s.startswith("set_tests_properties("):
                m = RE_SET_PROPS.match(s)
                if not m:
                    continue
                name = m.group(1) or m.group(2) or m.group(3)
                props = m.group(4) or ""
                if not name:
                    continue
                entry = tests.setdefault(name, {"cmd": None, "env": [], "workdir": None})
                env_m = RE_PROP_ENV.search(props) or RE_PROP_ENV_UNQUOTED.search(props)
                if env_m:
                    # CMake joins ENVIRONMENT with ';'
                    env_items = [p for p in env_m.group(1).split(";") if p and "=" in p]
                    entry["env"] = env_items
                wd_m = RE_PROP_WD.search(props) or RE_PROP_WD_UNQUOTED.search(props)
                if wd_m:
                    entry["workdir"] = wd_m.group(1)
    return tests


def load_json_tests(path: Optional[Path]) -> List[dict]:
    if not path or not path.is_file() or path.stat().st_size == 0:
        return []
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
        # Some ctest versions print warnings before JSON; slice from first '{'
        start = raw.find("{")
        if start < 0:
            return []
        data = json.loads(raw[start:])
    except Exception as exc:
        print(f"warning: failed to parse ctest json: {exc}", file=sys.stderr)
        return []
    return list(data.get("tests") or [])


def _is_runnable(path: Path) -> bool:
    try:
        return path.is_file() and (os.access(path, os.X_OK) or path.stat().st_mode & 0o111)
    except OSError:
        return False


def resolve_cmd(
    name: str,
    json_cmd,
    ctest_map: Dict[str, dict],
    build_dir: Path,
) -> Optional[List[str]]:
    cmd = json_cmd
    if isinstance(cmd, str):
        cmd = [cmd] if cmd else None
    if isinstance(cmd, list) and cmd:
        # Prefer listed command if the binary exists; otherwise keep trying fallbacks.
        primary = Path(str(cmd[0]))
        if _is_runnable(primary) or primary.exists():
            return [str(c) for c in cmd]
    mapped = ctest_map.get(name) or {}
    if mapped.get("cmd"):
        mapped_cmd = list(mapped["cmd"])
        primary = Path(str(mapped_cmd[0]))
        if _is_runnable(primary) or primary.exists():
            return mapped_cmd
    for sub in ("bin", "bin/Debug", "bin/Release", "bin/RelWithDebInfo"):
        candidate = build_dir / sub / name
        if _is_runnable(candidate):
            return [str(candidate)]
    # Last resort: search shallowly under build_dir for an executable with this name.
    for candidate in build_dir.rglob(name):
        if _is_runnable(candidate) and candidate.name == name:
            return [str(candidate)]
    return None


def name_allowed(name: str, include_re: Optional[re.Pattern], exclude_re: Optional[re.Pattern]) -> bool:
    if not name:
        return False
    if include_re is not None and not include_re.search(name):
        return False
    if exclude_re is not None and exclude_re.search(name):
        return False
    return True


def scan_bin_fallback(build_dir: Path, include_re, exclude_re) -> Dict[str, List[str]]:
    """Last-resort: treat unit-test-like executables under the build tree as tests."""
    out: Dict[str, List[str]] = {}
    candidates = []
    for sub in ("bin", "bin/Debug", "bin/Release", "bin/RelWithDebInfo"):
        d = build_dir / sub
        if d.is_dir():
            candidates.extend(sorted(d.iterdir()))
    # Also catch unit tests that did not land in bin/ for any reason.
    try:
        candidates.extend(build_dir.rglob("*-test"))
        candidates.extend(build_dir.rglob("assertions-in-tests"))
    except OSError:
        pass
    seen = set()
    for p in candidates:
        try:
            p = p.resolve()
        except OSError:
            continue
        if p in seen or not _is_runnable(p):
            continue
        seen.add(p)
        name = p.name
        if name in {"inkscape", "inkview", "cmake", "ninja", "ctest", "cpack"}:
            continue
        if not name_allowed(name, include_re, exclude_re):
            continue
        out[name] = [str(p)]
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build-dir", type=Path, required=True)
    ap.add_argument("--wrapper", type=Path, required=True)
    ap.add_argument("--out-script", type=Path, required=True)
    ap.add_argument("--ctest-json", type=Path, default=None)
    ap.add_argument("--include-regex", default=".*")
    ap.add_argument("--exclude-regex", default="")
    ap.add_argument("--max-tests", type=int, default=0, help="0 = no limit")
    ap.add_argument("--diagnostics", type=Path, default=None)
    args = ap.parse_args(argv)

    build_dir = args.build_dir.resolve()
    include_re = re.compile(args.include_regex) if args.include_regex else None
    exclude_re = re.compile(args.exclude_regex) if args.exclude_regex else None

    ctest_map = parse_ctest_files(build_dir)
    json_tests = load_json_tests(args.ctest_json)

    # Prefer JSON order when available (matches ctest filters if used), else CTest map.
    ordered_names: List[str] = []
    json_by_name: Dict[str, dict] = {}
    if json_tests:
        for t in json_tests:
            n = t.get("name") or ""
            if n and n not in json_by_name:
                json_by_name[n] = t
                ordered_names.append(n)
    else:
        ordered_names = sorted(ctest_map.keys())

    selected: List[Tuple[str, List[str], List[str], Optional[str]]] = []
    skipped_no_cmd = []
    skipped_filter = []

    for name in ordered_names:
        if not name_allowed(name, include_re, exclude_re):
            skipped_filter.append(name)
            continue
        jt = json_by_name.get(name, {})
        cmd = resolve_cmd(name, jt.get("command"), ctest_map, build_dir)
        if not cmd:
            skipped_no_cmd.append(name)
            continue

        # Env / workdir: prefer JSON properties, else CTestTestfile map
        env_exports: List[str] = []
        workdir = None
        for prop in jt.get("properties") or []:
            pname = prop.get("name")
            pval = prop.get("value")
            if pname == "ENVIRONMENT":
                vals = pval if isinstance(pval, list) else [pval]
                for item in vals:
                    if item and "=" in str(item):
                        env_exports.append(str(item))
            elif pname == "WORKING_DIRECTORY" and pval:
                workdir = str(pval)
        mapped = ctest_map.get(name) or {}
        if not env_exports and mapped.get("env"):
            env_exports = list(mapped["env"])
        if not workdir and mapped.get("workdir"):
            workdir = mapped["workdir"]

        selected.append((name, cmd, env_exports, workdir))
        if args.max_tests and len(selected) >= args.max_tests:
            break

    # If still empty, scan bin/
    if not selected:
        for name, cmd in scan_bin_fallback(build_dir, include_re, exclude_re).items():
            selected.append((name, cmd, [], None))
            if args.max_tests and len(selected) >= args.max_tests:
                break

    lines = [
        "#!/usr/bin/env bash",
        "set -uo pipefail",
        f"WRAPPER={shlex.quote(str(args.wrapper))}",
        "failures=0",
    ]
    for name, cmd, env_exports, workdir in selected:
        cmd_s = " ".join(shlex.quote(str(c)) for c in cmd)
        lines.append(f'echo ">> {name}"')
        lines.append("(")
        for item in env_exports:
            k, _, v = item.partition("=")
            lines.append(f"  export {shlex.quote(k)}={shlex.quote(v)}")
        if workdir:
            lines.append(f"  cd {shlex.quote(workdir)}")
        lines.append(f'  "$WRAPPER" {cmd_s}')
        lines.append(")")
        lines.append("rc=$?")
        lines.append("if [[ $rc -ne 0 ]]; then failures=$((failures+1)); fi")
    lines.append('echo "launcher failures (non-valgrind): $failures"')
    lines.append("exit 0")

    args.out_script.parent.mkdir(parents=True, exist_ok=True)
    args.out_script.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(args.out_script, 0o755)

    diag = {
        "build_dir": str(build_dir),
        "ctest_map_count": len(ctest_map),
        "json_test_count": len(json_tests),
        "selected_count": len(selected),
        "selected": [n for n, *_ in selected],
        "skipped_filter_count": len(skipped_filter),
        "skipped_no_cmd_count": len(skipped_no_cmd),
        "skipped_no_cmd_sample": skipped_no_cmd[:30],
        "include_regex": args.include_regex,
        "exclude_regex": args.exclude_regex,
        "bin_exists": (build_dir / "bin").is_dir(),
        "bin_sample": sorted(p.name for p in (build_dir / "bin").iterdir())[:40]
        if (build_dir / "bin").is_dir()
        else [],
    }
    if args.diagnostics:
        args.diagnostics.parent.mkdir(parents=True, exist_ok=True)
        args.diagnostics.write_text(json.dumps(diag, indent=2) + "\n", encoding="utf-8")

    print(
        f"wrote {args.out_script} with {len(selected)} runnable tests "
        f"(ctest_map={len(ctest_map)}, json={len(json_tests)}, "
        f"skipped_filter={len(skipped_filter)}, skipped_no_cmd={len(skipped_no_cmd)})"
    )
    if not selected:
        print("error: no runnable tests after enumeration", file=sys.stderr)
        print(json.dumps(diag, indent=2), file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
