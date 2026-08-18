#!/usr/bin/env bash
# scripts/patch_overlayfs_mountify.sh
# Mountify is a userspace/module-side overlayfs mount manager for
# KernelSU/Magisk — it needs CONFIG_OVERLAY_FS in the kernel and rides
# along as a flashable module zip, it does NOT get compiled into the
# kernel image. This script (a) turns on the kernel config it depends
# on, and (b) stages the module zip so package_anykernel.sh can bundle
# it as an extra release asset if you want one-flash convenience.
set -euo pipefail

: "${KERNEL_DIR:?}"
: "${ARCH:?}"
: "${DEFCONFIG:?}"
: "${MOUNTIFY_REPO:?}"
: "${MOUNTIFY_BRANCH:?}"

DEFCONFIG_PATH="$KERNEL_DIR/arch/${ARCH}/configs/${DEFCONFIG}"

for flag in CONFIG_OVERLAY_FS=y CONFIG_OVERLAY_FS_REDIRECT_DIR=y CONFIG_OVERLAY_FS_INDEX=y; do
  grep -q "^${flag%%=*}=" "$DEFCONFIG_PATH" 2>/dev/null || echo "$flag" >> "$DEFCONFIG_PATH"
done

echo "==> Staging Mountify module zip (bundled as a separate release asset, not compiled in)"
git clone --depth=1 -b "$MOUNTIFY_BRANCH" "$MOUNTIFY_REPO" "$GITHUB_WORKSPACE/mountify"
mkdir -p "$GITHUB_WORKSPACE/out/extra"
( cd "$GITHUB_WORKSPACE/mountify" && zip -r -q "$GITHUB_WORKSPACE/out/extra/Mountify.zip" . -x '.git/*' )
echo "Mountify.zip staged at out/extra/Mountify.zip"
