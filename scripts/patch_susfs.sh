#!/usr/bin/env bash
# scripts/patch_susfs.sh
# Applies susfs4ksu (pinned tag $SUSFS_TAG, branch $SUSFS_BRANCH) into
# $KERNEL_DIR on top of whichever KSU fork patch_ksu.sh just integrated.
# Follows the standard susfs4ksu layout: KernelSU/ patch, kernel/ patch,
# then loose fs/ + include/linux/ files copied in directly.
set -euo pipefail

if [ "${KSU_VARIANT:-}" = "none" ]; then
  echo "KSU_VARIANT is 'none'. Skipping SUSFS integration for vanilla kernel."
  exit 0
fi

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${SUSFS_REPO:?}"
: "${SUSFS_BRANCH:?}"
: "${SUSFS_TAG:?}"

if [ -z "${KSU_DIR:-}" ]; then
    if [ -d "$KERNEL_DIR/KernelSU-Next" ]; then
        KSU_DIR="KernelSU-Next"
    elif [ -d "$KERNEL_DIR/KernelSU" ]; then
        KSU_DIR="KernelSU"
    else
        echo "::error::KSU_DIR not set and could not be detected automatically."
        exit 1
    fi
fi

WORK="$GITHUB_WORKSPACE/susfs4ksu"
rm -rf "$WORK"
git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$WORK" \
  || { echo "::error::could not clone $SUSFS_REPO @ $SUSFS_BRANCH"; exit 1; }

( cd "$WORK" && git fetch --depth=1 origin "refs/tags/${SUSFS_TAG}" 2>/dev/null \
    && git checkout FETCH_HEAD ) || \
  echo "Tag ${SUSFS_TAG} not found on ${SUSFS_BRANCH}; using branch HEAD instead."

cd "$KERNEL_DIR"

echo "==> Copying susfs patch fragments"
cp "$WORK"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch "$KSU_DIR/" 2>/dev/null \
  || echo "  (no 10_enable_susfs_for_ksu.patch for this susfs source — fork may already carry susfs built-in)"

SUSFS_KMAIN="50_add_susfs_in_kernel-${KERNEL_VERSION_MAJOR}.${KERNEL_VERSION_MINOR}.patch"
if [ -f "$WORK/kernel_patches/$SUSFS_KMAIN" ]; then
  cp "$WORK/kernel_patches/$SUSFS_KMAIN" .
else
  cp "$WORK"/kernel_patches/50_add_susfs_in_kernel*.patch . 2>/dev/null || true
  SUSFS_KMAIN=$(basename "$(ls 50_add_susfs_in_kernel*.patch | head -n1)")
fi

mkdir -p fs include/linux
cp "$WORK"/kernel_patches/fs/* fs/ 2>/dev/null || true
cp "$WORK"/kernel_patches/include/linux/* include/linux/ 2>/dev/null || true

echo "==> Applying KernelSU-side susfs patch"
if [[ "${KSU_VARIANT:-}" == "resukisu" || "${KSU_VARIANT:-}" == "sukisu-ultra" || "${KSU_VARIANT:-}" == "xxksu" ]]; then
  echo "  Skipping 10_enable_susfs_for_ksu.patch since KSU_VARIANT '${KSU_VARIANT}' usually has SUSFS built-in."
else
  if [ -f "$KSU_DIR/10_enable_susfs_for_ksu.patch" ]; then
    ( cd "$KSU_DIR" && patch -p1 --fuzz=1 < 10_enable_susfs_for_ksu.patch ) \
      || echo "::warning::10_enable_susfs_for_ksu.patch had rejects — check ${KSU_DIR}/*.rej"
  fi
fi

echo "==> Applying kernel-side susfs patch ($SUSFS_KMAIN)"
patch -p1 --fuzz=3 < "$SUSFS_KMAIN" \
  || echo "::warning::$SUSFS_KMAIN had rejects — check *.rej files, this is normal on heavily-modified vendor trees and usually needs a manual pass"

DEFCONFIG_PATH="arch/${ARCH}/configs/${DEFCONFIG}"
for flag in \
  CONFIG_KSU_SUSFS=y \
  CONFIG_KSU_SUSFS_SUS_PATH=y \
  CONFIG_KSU_SUSFS_SUS_MOUNT=y \
  CONFIG_KSU_SUSFS_SUS_KSTAT=y \
  CONFIG_KSU_SUSFS_TRY_UMOUNT=y \
  CONFIG_KSU_SUSFS_SPOOF_UNAME=y \
  CONFIG_KSU_SUSFS_ENABLE_LOG=y \
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y \
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y \
  CONFIG_KSU_SUSFS_OPEN_REDIRECT=y ; do
  grep -q "^${flag%%=*}=" "$DEFCONFIG_PATH" 2>/dev/null || echo "$flag" >> "$DEFCONFIG_PATH"
done

echo "susfs4ksu integration step finished. Review *.rej files above if any were printed — non-GKI vendor trees this old routinely need a couple of hand-applied hunks."
