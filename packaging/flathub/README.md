# Flathub local debug builds

This directory vendors the [Flathub Inkscape Flatpak](https://github.com/flathub/org.inkscape.Inkscape)
manifest and helpers so developers can reproduce Flathub packaging issues
locally, without leaving this repository.

## Contents

| Path | Purpose |
|------|---------|
| `org.inkscape.Inkscape.json` | Flatpak manifest (inkscape module sources point at the local repo via `"type": "dir"`) |
| `python3-tkinter.yaml` | Tkinter module used by extensions |
| `python3-requirements.json` | Python runtime deps for extensions |
| `requirements.txt` | Source list for the requirements fragment |
| `patches/` | Patches applied during the Flatpak build |
| `shared-modules/` | Vendored Flathub `shared-modules` fragment(s) |
| `build-flathub.sh` | Run `flatpak-builder` against the local tree |
| `run-flathub.sh` | Install/run the locally built Flatpak |
| `configure-flathub-cmake.sh` | Configure a normal CMake/`build/` tree with `CMAKE_BUILD_TYPE=Flathub` |

## `CMAKE_BUILD_TYPE=Flathub`

A custom CMake build type is registered in the top-level `CMakeLists.txt`.
It is based on `RelWithDebInfo` and adds the same
`-DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_66` define that the Flathub
manifest passes via `build-options.cxxflags`.  The Flatpak manifest sets
`-DCMAKE_BUILD_TYPE=Flathub` for the inkscape module; you can also configure
a host-side mirror build with `configure-flathub-cmake.sh`.

## Local vs published Flathub

The published [flathub/org.inkscape.Inkscape](https://github.com/flathub/org.inkscape.Inkscape)
manifest still targets the **1.4.x / GTK3** release tarball.  The copy under
`packaging/flathub/` is adapted for **debugging the current source tree**
(GTK4 / gtkmm-4 / sigc++-3 / glibmm-2.68), with the inkscape module built
from the local checkout (`"type": "dir", "path": "../.."`).

Extra local-only `config-opts` on the inkscape module:

- `-DCMAKE_BUILD_TYPE=Flathub`
- `-DWITH_CAPYPDF=OFF` (avoids an in-sandbox network fetch during configure)

Re-sync the dep list/patches from upstream Flathub when you need to reproduce
an issue against the exact 1.4.x package; keep the dir source entry so your
local edits are what get built.

## Prerequisites

- `flatpak` and `flatpak-builder`
- Network access the first time (pulls `org.gnome.Platform` / `org.gnome.Sdk`)
- Enough disk in `build/` for the Flatpak state/build/repo directories

On Ubuntu/Debian (host or Linux VM such as Colima/Lima):

```bash
sudo apt-get update
sudo apt-get install -y flatpak flatpak-builder
```

## Build the Flatpak (local debug)

Prefer running the builder **inside Linux** (native host, container, or a VM
such as Colima). From the repository root:

```bash
cd /path/to/this/repo
./packaging/flathub/build-flathub.sh

# Later runs (SDK already installed):
SKIP_SDK_INSTALL=1 ./packaging/flathub/build-flathub.sh

# Small VM disk (~20G Colima): disable ccache, fewer jobs
SKIP_SDK_INSTALL=1 FLATHUB_NO_CCACHE=1 FLATHUB_JOBS=2 \
  ./packaging/flathub/build-flathub.sh
```

Example when invoking a Colima VM shell from the host (adjust the profile
name and repo path for your setup):

```bash
colima ssh -- bash -lc '
  REPO=/path/to/this/repo
  cd "$REPO"
  ./packaging/flathub/build-flathub.sh
'
```

Artifacts:

- `build/flathub-repo/` — local OSTree repo to install/run from (always)
- `build/flathub-build/` and `build/flathub-state/` — default when the tree
  is on a normal local filesystem
- On Colima/Lima **virtiofs/9p** mounts, build+state dirs default to
  `~/.cache/inkscape-flathub/{build,state}` (must share one filesystem;
  avoids permission errors on restrictive modes set by `flatpak-builder`).
  Override with `FLATHUB_BUILD_DIR` / `FLATHUB_STATE_DIR` if needed.

Re-runs reuse the state dir; `--force-clean` is already the default in
`build-flathub.sh`.  Extra `flatpak-builder` flags can be appended, e.g.
`./packaging/flathub/build-flathub.sh --stop-at=inkscape`.

Environment variables (all optional):

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLATHUB_REPO_DIR` | `<repo>/build/flathub-repo` | Local Flatpak OSTree repo |
| `FLATHUB_STATE_DIR` | see above | `flatpak-builder` state/cache |
| `FLATHUB_BUILD_DIR` | see above | `flatpak-builder` build dir |
| `FLATHUB_JOBS` | `nproc` | Parallel jobs |
| `FLATHUB_NO_CCACHE` | unset | Set `1` to disable ccache (saves disk) |
| `SKIP_SDK_INSTALL` | unset | Set `1` to skip GNOME SDK/runtime install |

## Run the locally built Flatpak

```bash
./packaging/flathub/run-flathub.sh
# or with args:
./packaging/flathub/run-flathub.sh --version
```

Or manually:

```bash
flatpak --user remote-add --no-gpg-verify --if-not-exists \
  inkscape-flathub-local build/flathub-repo
flatpak --user install -y inkscape-flathub-local \
  org.inkscape.Inkscape//local-debug
flatpak run org.inkscape.Inkscape//local-debug --version
```

## Host-side CMake mirror (optional, fast iteration)

Uses the repository `build/` directory and the Ninja generator:

```bash
./packaging/flathub/configure-flathub-cmake.sh
ninja -C build
```

This does **not** reproduce the Flatpak sandbox/runtime; it only mirrors the
compiler/build-type flags used by Flathub.  Use `build-flathub.sh` for full
packaging fidelity.

## Syncing with upstream Flathub

Re-fetch the manifest/patches from
https://github.com/flathub/org.inkscape.Inkscape and keep the inkscape
module `sources` entry as a local `dir` source:

```json
"sources": [ { "type": "dir", "path": "../.." } ]
```

so local edits in this checkout are what get built.