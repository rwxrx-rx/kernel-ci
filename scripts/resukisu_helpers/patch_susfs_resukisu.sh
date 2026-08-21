#!/usr/bin/env bash
# scripts/patch_susfs_resukisu.sh
#
# susfs4ksu 2.2.0 for ReSukiSU, via whole-file tree overlay instead of
# `patch -p1 --fuzz`. patches/susfs_v220/tree/ contains files that are
# ALREADY 3-way merged (camellia device code + susfs v2.2.0 hooks) —
# they get copied straight over the vendor tree, not diffed against it.
# This is what actually fixed the susfs integration: the generic
# susfs4ksu unified diff rejected almost everything on this vendor tree
# (kernel/selinux/rules.c, selinux.c, selinux.h all failed outright);
# this pre-merged set sidesteps that entirely by not being a diff.
#
# Source: adapted from a working reference build for the same device
# (camellia) + ReSukiSU + susfs v2.2.0 combination.
set -euo pipefail
: "${KERNEL_DIR:?}"
: "${GITHUB_WORKSPACE:?}"

TREE="$GITHUB_WORKSPACE/patches/susfs_v220/tree"
cd "$KERNEL_DIR"

if [ ! -d "$TREE" ]; then
  echo "::error::pre-merged susfs tree not found at $TREE — did patches/susfs_v220/ get committed to the repo?"
  exit 1
fi

echo "=== susfs v2.2.0 install for ReSukiSU (whole-file overlay, no patch/fuzz) ==="

echo "[1] Installing merged tree files..."
COUNT=0
while IFS= read -r src; do
  rel="${src#"$TREE"/}"
  mkdir -p "$(dirname "$rel")"
  cp -f "$src" "$rel"
  COUNT=$((COUNT + 1))
done < <(find "$TREE" -type f)
echo "    installed $COUNT files"

# --- Inline call-sites (the ones the tree-overlay's files above don't
# already contain — those live in files this overlay doesn't touch,
# like fs/exec.c's do_execve, fs/stat.c's newfstatat, kernel/sys.c's
# setresuid, drivers/input/input.c) ------------------------------------
echo "[2] Injecting ReSukiSU SUSFS inline call-sites..."
python3 "$(dirname "${BASH_SOURCE[0]}")/apply_resukisu_inline_hooks.py" "$KERNEL_DIR"

# --- SUS_MAP (maps/smaps/pagemap hiding) — best-effort ------------------
# This one is pinned to one exact upstream fs/proc/task_mmu.c commit's
# SHA256. If this tree's task_mmu.c doesn't match byte-for-byte, it WILL
# fail — that's by design (fail-closed rather than silently mis-patch),
# but SUS_MAP is an enhancement on top of core susfs, not a hard
# requirement, so a failure here is a warning, not a build-stopper.
echo "[3] Installing SUS_MAP (fs/proc/task_mmu.c) — best-effort..."
if python3 "$(dirname "${BASH_SOURCE[0]}")/apply_susmap_414.py" "$KERNEL_DIR"; then
  echo "    SUS_MAP installed."
else
  echo "::warning::SUS_MAP port didn't apply (task_mmu.c on this tree doesn't match the exact commit this port was made against) — continuing without it. susfs core (path/mount/kstat hiding) is unaffected."
  sed -i '/CONFIG_KSU_SUSFS_SUS_MAP/d' "arch/${ARCH}/configs/${DEFCONFIG}" 2>/dev/null || true
fi

# --- IDA compat shim (4.14 lacks ida_alloc_min/ida_free that the merged
# fs/namespace.c SUS_MOUNT code calls; no-op on kernels >=4.19) ---------
echo "[4] Installing IDA compat shim..."
SHIM="include/linux/susfs_ida_compat.h"
cat > "$SHIM" <<'SHIMEOF'
#ifndef _SUSFS_IDA_COMPAT_H
#define _SUSFS_IDA_COMPAT_H
#include <linux/version.h>
#include <linux/idr.h>
#include <linux/gfp.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(4,19,0)
#ifndef SUSFS_HAVE_IDA_ALLOC_MIN
#define SUSFS_HAVE_IDA_ALLOC_MIN
static inline int ida_alloc_min(struct ida *ida, unsigned int min, gfp_t gfp)
{
	return ida_simple_get(ida, min, 0, gfp);
}
static inline void ida_free(struct ida *ida, unsigned int id)
{
	ida_simple_remove(ida, id);
}
#endif
#endif
#endif /* _SUSFS_IDA_COMPAT_H */
SHIMEOF
grep -q "susfs_ida_compat.h" fs/namespace.c || sed -i '1i#include <linux/susfs_ida_compat.h>' fs/namespace.c
grep -q "susfs_ida_compat.h" include/linux/susfs.h || sed -i '1i#include <linux/susfs_ida_compat.h>' include/linux/susfs.h

echo "[5] Wiring fs/susfs.c into the build..."
grep -q 'susfs.o' fs/Makefile || echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile

echo "[6] Sanity: no leftover 3-way-merge conflict markers..."
MARKER_HIT=0
while IFS= read -r src; do
  rel="${src#"$TREE"/}"
  if grep -nE '^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)' "$rel" 2>/dev/null; then
    echo "::error::conflict marker left in $rel"
    MARKER_HIT=1
  fi
done < <(find "$TREE" -type f)
[ "$MARKER_HIT" = "0" ] || exit 1

echo "susfs v2.2.0 (ReSukiSU) install done. Version: $(grep -E '^#define SUSFS_VERSION' include/linux/susfs.h 2>/dev/null || echo unknown)"
