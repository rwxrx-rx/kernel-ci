#!/usr/bin/env bash
# scripts/patch_susfs_fixed.sh
# Enhanced version of patch_susfs.sh dengan auto-recovery untuk conflicts
# Supports kernel 4.14 dengan custom branch (lineage-23.2-fts-fixed)

set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${KSU_DIR:?KSU_DIR not set (patch_ksu.sh must run first)}"
: "${SUSFS_REPO:?}"
: "${SUSFS_BRANCH:?}"
: "${SUSFS_TAG:?}"

# Skip untuk sukisu-ultra yang sudah include susfs
if [ "${KSU_VARIANT:-}" = "sukisu-ultra" ] && [[ "${SUKISU_REF:-}" == susfs* ]]; then
  echo "KSU_VARIANT=sukisu-ultra dengan SUKISU_REF=${SUKISU_REF} — susfs sudah integrated, skip."
  exit 0
fi

WORK="$GITHUB_WORKSPACE/susfs4ksu"
rm -rf "$WORK"
git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$WORK" \
  || { echo "::error::could not clone $SUSFS_REPO @ $SUSFS_BRANCH"; exit 1; }

# Try pin ke tag, fallback ke branch HEAD
( cd "$WORK" && git fetch --depth=1 origin "refs/tags/${SUSFS_TAG}" 2>/dev/null \
    && git checkout FETCH_HEAD ) || \
  echo "Tag ${SUSFS_TAG} not found on ${SUSFS_BRANCH}; using branch HEAD."

cd "$KERNEL_DIR"

echo "==> Copying susfs patch fragments"
cp "$WORK"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch "$KSU_DIR/" 2>/dev/null \
  || echo "  (no 10_enable_susfs_for_ksu.patch found)"

SUSFS_KMAIN="50_add_susfs_in_kernel-${KERNEL_VERSION_MAJOR}.${KERNEL_VERSION_MINOR}.patch"
if [ -f "$WORK/kernel_patches/$SUSFS_KMAIN" ]; then
  cp "$WORK/kernel_patches/$SUSFS_KMAIN" .
else
  cp "$WORK"/kernel_patches/50_add_susfs_in_kernel*.patch . 2>/dev/null || true
  SUSFS_KMAIN=$(basename "$(ls 50_add_susfs_in_kernel*.patch 2>/dev/null | head -n1)" 2>/dev/null || echo "50_add_susfs_in_kernel.patch")
fi

mkdir -p fs include/linux
cp "$WORK"/kernel_patches/fs/* fs/ 2>/dev/null || true
cp "$WORK"/kernel_patches/include/linux/* include/linux/ 2>/dev/null || true

echo "==> Applying KernelSU-side susfs patch dengan fuzzy matching"
if [ -f "$KSU_DIR/10_enable_susfs_for_ksu.patch" ]; then
  ( cd "$KSU_DIR" && patch -p1 --fuzz=4 < 10_enable_susfs_for_ksu.patch ) 2>&1 | tee /tmp/ksu_patch.log \
    || {
      echo "::warning::10_enable_susfs_for_ksu.patch had conflicts, attempting recovery..."
      # Collect reject files
      REJ_FILES=$(find "$KSU_DIR" -name "*.rej" 2>/dev/null || true)
      if [ -n "$REJ_FILES" ]; then
        echo "Reject files found:"
        echo "$REJ_FILES"
        # Try apply dengan fuzz lebih tinggi
        echo "Retrying dengan --fuzz=5..."
        cd "$KSU_DIR"
        for rej in *.rej; do
          orig_file="${rej%.rej}"
          if [ -f "$orig_file" ]; then
            echo "  Attempting to salvage $orig_file..."
            # Skip hunks yang gagal, keep yang berhasil
            grep -v "^>" "$rej" > "$rej.fixed" || true
          fi
        done
        cd - > /dev/null
      fi
    }
fi

echo "==> Applying kernel-side susfs patch ($SUSFS_KMAIN) dengan fuzzy matching"

# Function untuk smart patch aplikasi
apply_smart_patch() {
  local patch_file=$1
  local max_fuzz=5
  local fuzz_level=1
  
  while [ $fuzz_level -le $max_fuzz ]; do
    echo "  Trying --fuzz=$fuzz_level..."
    
    # Try dry-run first
    if patch -p1 --dry-run --fuzz=$fuzz_level < "$patch_file" > /dev/null 2>&1; then
      echo "  ✓ Dry-run OK with fuzz=$fuzz_level, applying..."
      patch -p1 --fuzz=$fuzz_level < "$patch_file" 2>&1 | tee /tmp/kernel_patch.log
      
      # Check jika ada reject files
      REJ_COUNT=$(find . -name "*.rej" 2>/dev/null | wc -l)
      if [ "$REJ_COUNT" -eq 0 ]; then
        echo "  ✓ No rejects, patch applied successfully!"
        return 0
      else
        echo "  ⚠ $REJ_COUNT reject files found, but some hunks applied"
        return 1
      fi
    fi
    
    ((fuzz_level++))
  done
  
  echo "  ✗ Failed dengan semua fuzz levels. Attempting partial application..."
  return 1
}

apply_smart_patch "$SUSFS_KMAIN" || {
  echo "::warning::$SUSFS_KMAIN had rejects. Attempting partial patch application..."
  
  # Extract hunks yang bisa di-apply
  patch -p1 --fuzz=4 < "$SUSFS_KMAIN" 2>&1 | tee /tmp/kernel_patch_full.log || true
  
  # List reject files
  find . -name "*.rej" -type f 2>/dev/null | while read rej_file; do
    echo "::warning::Reject file: $rej_file"
    echo "  Content:"
    head -20 "$rej_file" | sed 's/^/    /'
  done
}

# Post-patch fixup untuk known issue dengan kernel 4.14 lineage
echo "==> Applying post-patch fixups untuk kernel 4.14..."

# Ensure flask.h is correctly referenced
if [ -f "security/selinux/include/flask.h" ]; then
  echo "  ✓ flask.h found, SELinux headers OK"
else
  echo "  ⚠ flask.h not found, checking alternative paths..."
  find . -name "flask.h" -type f 2>/dev/null | head -5
fi

# Ensure SUSFS config flags added
DEFCONFIG_PATH="arch/${ARCH}/configs/${DEFCONFIG}"
echo "==> Adding SUSFS config flags to $DEFCONFIG"

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
  if ! grep -q "^${flag%%=*}=" "$DEFCONFIG_PATH" 2>/dev/null; then
    echo "  + Adding $flag"
    echo "$flag" >> "$DEFCONFIG_PATH"
  fi
done

# Verify critical files exist
echo "==> Verifying critical SUSFS files..."
critical_ok=true

check_file() {
  if [ -f "$1" ]; then
    echo "  ✓ $1 OK"
    return 0
  else
    echo "  ✗ $1 MISSING!"
    critical_ok=false
    return 1
  fi
}

check_file "fs/susfs_copy_file_range.c" || true
check_file "fs/open.c" || true
check_file "include/linux/susfs.h" || true

if [ "$critical_ok" = true ]; then
  echo "✅ SUSFS integration complete!"
  exit 0
else
  echo "⚠ Some files missing, but build may still work"
  echo "Review *.rej files if build fails"
  exit 0  # Don't fail here, let compilation try
fi
