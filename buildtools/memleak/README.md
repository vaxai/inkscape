# Memory leak detection (Valgrind / Helgrind)

Scripts to run Inkscape's CTest suite under **Valgrind memcheck** (and optionally
**helgrind**), then **diff definite leaks** between the current branch and a
target branch (default `master`). Only **newly introduced** leak signatures fail
CI — pre-existing baseline noise is ignored.

## Requirements

- Linux (Valgrind)
- `valgrind`, `cmake`, `ninja`, `python3`
- Build with debug symbols: `RelWithDebInfo` or `Debug`
- Inkscape deps installed (same as a normal debug build)

## Quick local run (current build only)

```bash
cmake -S . -B build-memleak -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DBUILD_TESTING=ON \
  -DTESTS_WITH_ASAN=OFF \
  -DWITH_ASAN=OFF
cmake --build build-memleak --parallel "$(nproc)"

./buildtools/memleak/run_memcheck.sh \
  --build-dir build-memleak \
  --label current \
  --tests unit
```

> **Important:** do not enable ASan (`TESTS_WITH_ASAN` / `WITH_ASAN`) in the
> Valgrind build; the two tools conflict at runtime.

Outputs land in `build-memleak/memleak_reports/current/`:

| File | Purpose |
|------|---------|
| `current.memcheck.jsonl` | Normalized actionable leaks |
| `current.memcheck.summary.md` | Human summary |
| `raw/*.log` | Raw Valgrind logs |
| `manifest.json` | Run metadata |

## Full branch diff (baseline vs HEAD)

```bash
./buildtools/memleak/run_branch_diff.sh --target master --tests unit
```

This will:

1. Create/update a git worktree for the target ref
2. Configure+build baseline and current (`RelWithDebInfo`)
3. Run memcheck (`--tests unit` by default for speed)
4. Write `reports/diff.md` + `reports/diff.json`
5. Exit **non-zero** only if HEAD introduces **new definite leak signatures**

Environment knobs mirror CLI flags: `MEMLEAK_TARGET_REF`, `MEMLEAK_BUILD_ROOT`,
`MEMLEAK_TESTS_MODE`, `MEMLEAK_TOOL`, `MEMLEAK_BUILD_JOBS`, etc.

## Helgrind (threading races)

Helgrind is **much slower** and noisier; use on-demand:

```bash
MEMLEAK_TOOL=helgrind ./buildtools/memleak/run_memcheck.sh \
  --build-dir build-memleak --label helgrind-current --tests unit --tool helgrind
```

The GitHub workflow runs helgrind only when the `helgrind` input/label is set,
not on every PR.

## Accuracy / low noise design

1. **Actionable kinds only** — default parse keeps `definite` leaks (memcheck)
2. **Inkscape-owned stacks** — records without an Inkscape/src frame are dropped by default
3. **Suppressions** — `valgrind.supp` covers Fontconfig/GLib/GTK/X11/gtest init (reachable/possible/indirect only; definite Inkscape leaks are not blanket-suppressed)
4. **Signature diff vs target branch** — only *new* signatures fail; baseline debt does not
5. **Normalized stacks** — addresses and build prefixes stripped for stable signatures
6. **Optional growth gate** — `--allow-growth-bytes` can fail if an existing signature worsens

## GitHub Actions

Workflow: `.github/workflows/memleak.yml`

- Triggers: `pull_request`, `workflow_dispatch`
- Builds baseline (PR base / `master`) and PR head with ccache
- Runs **unit-filtered** memcheck only (excludes `perf_`, `render_`, `cli_`, LPE suites)
- Uploads artifacts + posts a job summary from `diff.md`
- Fails the job when `compare_leaks.py` reports introduced signatures

## Interpreting failures

Open the workflow artifact `memleak-reports` and read `reports/diff.md`. Each
introduced signature lists the owning test binary and a normalized stack. Fix the
leak in Inkscape code, or if it is a confirmed third-party one-time init issue,
add a **narrow** suppression to `valgrind.supp` (prefer suppressing reachable/
possible in system libs, not definite leaks in `src/`).
