# Camellia (POCO M3 Pro 5G / Redmi Note 10 5G) Kernel CI

GitHub Actions pipeline for building the 4.14 non‑GKI kernel with a choice
of KernelSU fork, susfs4ksu 2.2.0, OverlayFS + Mountify, a swappable clang
toolchain, and a swappable device tree — packaged as AnyKernel3 and shipped
to a GitHub Release and/or Telegram.

## Layout

```
manifest/                  ← edit THIS, not the workflow YAML, to change device/forks/toolchains
  device.env                 kernel repo, branch, defconfig, arch
  ksu-variants.env            KernelSU fork setup.sh URLs, susfs4ksu source, Mountify
  toolchains.env              AOSP clang / Proton clang sources

.github/actions/            composite actions (share the *same* checkout — no slow
  setup-toolchain/            multi-GB artifact transfer between jobs)
  clone-patch/
  build-kernel/
  package-anykernel/

.github/workflows/
  build-kernel.yml            ← the one you run. workflow_dispatch inputs choose
                                 variant / clang / device tree / release target.
  manager-build.yml           reusable: builds the manager APK for the chosen fork
  release.yml                 reusable: GitHub Release + Telegram push

scripts/
  patch_ksu.sh                 installs the selected fork, forces manual (non-kprobe) hook
  patch_susfs.sh                applies susfs4ksu on top of it
  patch_overlayfs_mountify.sh   CONFIG_OVERLAY_FS + stages Mountify.zip
  patch_features.sh             applies whichever optional feature toggles were turned on
  build_anykernel3.sh           packages Image/dtb/dtbo into a flashable zip
  gen_changelog.sh              one script, two outputs: changelog.md (Release) +
                                 changelog_telegram.txt (unused now, kept for reference)
  telegram_lib.sh               shared helpers (friendly names, send/edit message)
  telegram_build_start.sh       "🤖 Build Engine Started" message, remembers its message_id
  telegram_progress.sh          edits that same message in place — [1/4]..[4/4] live progress
  telegram_build_done.sh        rich "⚡ Kernel Ready" message + uploads the zip
  telegram_notify.sh            legacy batch sender (message + N files), not called by any
                                 workflow anymore but kept around if you want a summary post
```

## Telegram notifications

Sent **live, per build variant, from the `build-kernel` job itself** — not
batched at the end — so vanilla and KSU builds (when `build_target: both`)
each get their own start message, their own progress updates, and their
own "Kernel Ready" post with the correct zip attached:

1. **Build started** — device, codename, branch, KSU engine, who triggered it
2. **Progress** — the *same* message is edited in place through
   `[1/4] Cloning & patching...` → `[2/4] Compiling...` →
   `[3/4] Packaging AnyKernel3...` → `[4/4] Uploading...` (no message spam)
3. **Kernel Ready** — active-features checklist, last 5 commits with
   relative time + author, a link to the commit, then the zip itself with
   its size and SHA256

The GitHub Release (if you also picked `github` or `both`) still happens
separately at the end via `release.yml`, aggregating every variant's zip
into one release with a merged changelog — that part didn't change.

Why composite actions instead of one reusable workflow per stage: a
`workflow_call` job runs on a fresh runner with nothing but artifacts you
explicitly upload/download — fine for the manager build and the release
step (small files), but re-uploading/downloading a full kernel source tree
between "clone", "patch", and "build" would add many minutes per run for no
benefit. Composite actions run as steps inside one job, so they share the
checkout and stay fast, while still keeping each concern in its own file.

## Required repo secrets

| Secret | Used for |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Bot API token from @BotFather |
| `TELEGRAM_CHAT_ID` | Channel/group/user ID the bot posts to |

`GITHUB_TOKEN` (auto-provided) handles the GitHub Release.

## Running a build

Actions tab → **Build Kernel (Camellia)** → Run workflow, then pick:
- **build_target**: `vanilla`, `ksu`, or `both` (parallel matrix)
- **component**: `kernel`, `manager`, or `both`
- **ksu_variant**: `kernelsu-next-legacy`, `resukisu`, `xxksu`, `sukisu-ultra`, `wildksu`
- **clang**: `proton-clang` or `aosp-clang`
- **susfs** / **overlayfs_mountify**: on/off
- **device_tree_repo** / **device_tree_branch**: leave blank to use `manifest/device.env`, or point at a different tree to swap it for this run only
- **release_channel**: `none`, `github`, `telegram`, or `both`

## Things you will need to touch before the first green build

This is a real non-GKI 4.14 vendor tree — no CI script can fully automate
that away, so be upfront about what's templated vs. what needs a hand pass:

1. **`manifest/device.env`** — `DEFCONFIG` and dtb/dtbo output paths are
   guesses at MediaTek mt6833 convention; confirm against your actual tree.
2. **`manifest/toolchains.env`** → `AOSP_CLANG_SUBDIR` — AOSP's prebuilt
   clang releases are versioned; pin the tag/subdir you actually want.
3. **`xxksu` variant** — I could not verify a canonical public repo for a
   fork by that exact name, so `manifest/ksu-variants.env` has a
   `CHANGE-ME` placeholder. The build fails fast with a clear error if you
   select `xxksu` without filling it in, rather than silently doing the
   wrong thing.
4. **susfs patch rejects** (`patch_susfs.sh`) — susfs4ksu's kernel-side
   patch is written against fairly clean trees; a heavily OEM-modified
   4.14 tree like this one routinely needs a few hunks applied by hand.
   The script applies what it can with `--fuzz=3` and prints a warning
   (not a hard failure) for the rest — check the Actions log / `*.rej`
   files after a run.
5. **Manager APK gradle task name** (`manager-build.yml`) — I used
   `:manager:assembleRelease` with a fallback to `assembleRelease`; forks
   vary in module layout, confirm against the fork's own CI config if it
   fails.
6. **"Universal manager APK"** — see the note inside `manager-build.yml`:
   there isn't actually one APK compatible with every fork (the
   manager↔kernel driver contract differs per fork), so this builds the
   correct manager for whichever fork you picked instead.
