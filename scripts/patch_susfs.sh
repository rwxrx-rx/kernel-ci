#!/usr/bin/env bash
# scripts/patch_susfs.sh
# Fallback susfs4ksu install for forks WITHOUT a proven tree-overlay
# (i.e. everything except ReSukiSU — see
# scripts/resukisu_helpers/patch_susfs_resukisu.sh for that one).
#
# Attempts the generic susfs4ksu unified-diff patch with increasing
# --fuzz. If it applies with real rejects, this does NOT set
# CONFIG_KSU_SUSFS=y anyway and call it done — a kernel that reports
# susfs as enabled while missing large parts of the actual patch isn't
# protected, it's just quiet about not being protected. On rejects, the
# SUSFS config flags are explicitly unset and the failure is visible in
# the log, so you know to either fix the anchors for this fork's tree or
# build without susfs for it — not find out from a device that's easier
# to detect root on than expected.
set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${KSU_DIR:?KSU_DIR not set (patch_ksu.sh must run first)}"
: "${SUSFS_REPO:?}"
: "${SUSFS_BRANCH:?}"
: "${SUSFS_TAG:?}"
: "${ARCH:?}"
: "${DEFCONFIG:?}"

DEFCONFIG_PATH="arch/${ARCH}/configs/${DEFCONFIG}"

unset_susfs_config() {
  echo "::warning::susfs4ksu did not apply cleanly for KSU_VARIANT=${KSU_VARIANT:-unknown} — building WITHOUT susfs rather than reporting it as enabled while broken. CONFIG_KSU_SUSFS* left unset."
  sed -i '/^CONFIG_KSU_SUSFS/d' "$DEFCONFIG_PATH" 2>/dev/null || true
}

WORK="$GITHUB_WORKSPACE/susfs4ksu"
rm -rf "$WORK"
git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$WORK" \
  || { echo "::error::could not clone $SUSFS_REPO @ $SUSFS_BRANCH"; exit 1; }

( cd "$WORK" && git fetch --depth=1 origin "refs/tags/${SUSFS_TAG}" 2>/dev/null \
    && git checkout FETCH_HEAD ) || \
  echo "Tag ${SUSFS_TAG} not found on ${SUSFS_BRANCH}; using branch HEAD."

cd "$KERNEL_DIR"

echo "==> Copying susfs patch fragments"
cp "$WORK"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch "$KSU_DIR/" 2>/dev/null \
  || echo "  (no 10_enable_susfs_for_ksu.patch for this susfs source)"

SUSFS_KMAIN="50_add_susfs_in_kernel-${KERNEL_VERSION_MAJOR}.${KERNEL_VERSION_MINOR}.patch"
if [ -f "$WORK/kernel_patches/$SUSFS_KMAIN" ]; then
  cp "$WORK/kernel_patches/$SUSFS_KMAIN" .
else
  cp "$WORK"/kernel_patches/50_add_susfs_in_kernel*.patch . 2>/dev/null || true
  SUSFS_KMAIN=$(basename "$(ls 50_add_susfs_in_kernel*.patch 2>/dev/null | head -n1)" 2>/dev/null || echo "")
fi

mkdir -p fs include/linux
cp "$WORK"/kernel_patches/fs/* fs/ 2>/dev/null || true
cp "$WORK"/kernel_patches/include/linux/* include/linux/ 2>/dev/null || true

TOTAL_REJECTS=0

echo "==> Applying KernelSU-side susfs patch"
if [ -f "$KSU_DIR/10_enable_susfs_for_ksu.patch" ]; then
  ( cd "$KSU_DIR" && patch -p1 --fuzz=3 < 10_enable_susfs_for_ksu.patch ) \
    || echo "::warning::10_enable_susfs_for_ksu.patch had rejects — check ${KSU_DIR}/*.rej"
  REJ=$(find "$KSU_DIR" -name '*.rej' 2>/dev/null | wc -l)
  TOTAL_REJECTS=$((TOTAL_REJECTS + REJ))
fi

if [ -n "$SUSFS_KMAIN" ] && [ -f "$SUSFS_KMAIN" ]; then
  echo "==> Applying kernel-side susfs patch ($SUSFS_KMAIN)"
  patch -p1 --fuzz=3 < "$SUSFS_KMAIN" \
    || echo "::warning::$SUSFS_KMAIN had rejects — check *.rej files"
  REJ=$(find . -maxdepth 3 -name '*.rej' 2>/dev/null | wc -l)
  TOTAL_REJECTS=$((TOTAL_REJECTS + REJ))
else
  echo "::warning::no kernel-side susfs patch found for kernel ${KERNEL_VERSION_MAJOR}.${KERNEL_VERSION_MINOR} in this susfs4ksu source"
  TOTAL_REJECTS=$((TOTAL_REJECTS + 1))
fi

if [ "$TOTAL_REJECTS" -gt 0 ]; then
  echo "::warning::$TOTAL_REJECTS reject file(s) total across both patches."
  unset_susfs_config
  exit 0
fi

echo "==> susfs4ksu applied cleanly, enabling config"
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
  key="${flag%%=*}"
  grep -q "^${key}=" "$DEFCONFIG_PATH" 2>/dev/null && sed -i "/^${key}=/d" "$DEFCONFIG_PATH"
  echo "$flag" >> "$DEFCONFIG_PATH"
done

echo "susfs4ksu integration finished cleanly for KSU_VARIANT=${KSU_VARIANT:-unknown}."
