#!/usr/bin/env bash
# scripts/patch_ksu_manual_hook_upstream.sh
#
# Manual-hook patch set for forks based on the ORIGINAL tiann/KernelSU
# API (ReSukiSU, SukiSU Ultra, Wild KSU) — NOT the same as
# patch_ksu_manual_hook.sh, which is KernelSU-Next-specific and uses
# different function names (do_execve vs do_execveat_common, an extra
# reboot.c hook KernelSU-Next added itself, etc). Mixing the two up is
# exactly the mistake that caused the earlier undefined-symbol chase —
# don't reuse one for the other.
#
# Source (archival, KernelSU dropped official non-GKI support at v1.0
# but the patch set itself is what these forks still build on):
# https://kernelsu.org/guide/how-to-integrate-for-non-gki.html
#
# CAVEAT, stated plainly: this is verified against upstream KernelSU's
# own documented API, which these forks inherit — it is NOT individually
# verified against ReSukiSU/SukiSU-Ultra/Wild KSU's actual current
# source, since none of them publish their own non-GKI manual-hook diff.
# If a fork has renamed something, the matching apply_patch call below
# fails loudly (not silently) and tells you exactly which anchor didn't
# match, same as the KernelSU-Next script.
set -euo pipefail
: "${KERNEL_DIR:?}"

cd "$KERNEL_DIR"
FAILED=0

apply_patch() {
  local file="$1" marker="$2"
  if [ ! -f "$file" ]; then
    echo "::error::$file not found — can't apply manual hook patch here."
    FAILED=1
    return
  fi
  if grep -q "$marker" "$file"; then
    echo "$file already patched, skipping."
    return
  fi
  if python3 -; then
    echo "==> Patched $file"
  else
    echo "::error::Failed to patch $file — anchor line not found. This fork/tree's version of this file differs from what upstream KernelSU documents. Paste me the relevant function from $file and I'll fix the anchor."
    FAILED=1
  fi
}

# --- fs/exec.c: do_execveat_common --------------------------------------
apply_patch "fs/exec.c" "ksu_handle_execveat_sucompat" << 'PYEOF'
import sys
path = "fs/exec.c"
with open(path) as f:
    text = f.read()

extern_anchor = "static int do_execveat_common(int fd, struct filename *filename,"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "extern bool ksu_execveat_hook __read_mostly;\n"
    "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n"
    "\t\t\tvoid *envp, int *flags);\n"
    "extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n"
    "\t\t\t\t void *argv, void *envp, int *flags);\n"
    "#endif\n"
)
if extern_anchor not in text:
    sys.exit(1)
text = text.replace(extern_anchor, extern_block + extern_anchor, 1)

# The function body opens with its first `return` (either straight to
# __do_execve_file, or after other setup) — insert right after the
# opening brace that follows the signature we just anchored on, by
# targeting the line immediately after the (now-duplicated) signature.
sig_end_anchor = "int flags)\n{"
call_block = (
    "\n#ifdef CONFIG_KSU\n"
    "\tif (unlikely(ksu_execveat_hook))\n"
    "\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
    "\telse\n"
    "\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n"
    "#endif"
)
if sig_end_anchor not in text:
    sys.exit(1)
text = text.replace(sig_end_anchor, sig_end_anchor + call_block, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

# --- fs/open.c: do_faccessat (or SYSCALL_DEFINE3 fallback for <4.17) -----
apply_patch "fs/open.c" "ksu_handle_faccessat" << 'PYEOF'
import sys
path = "fs/open.c"
with open(path) as f:
    text = f.read()

extern_block = (
    "#ifdef CONFIG_KSU\n"
    "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n"
    "\t\t\t int *flags);\n"
    "#endif\n\n"
)
call_block = (
    "\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
    "#endif"
)

# Try the >=4.17 form first.
anchor_new = "long do_faccessat(int dfd, const char __user *filename, int mode)"
lookup_anchor_new = "unsigned int lookup_flags = LOOKUP_FOLLOW;"
if anchor_new in text and lookup_anchor_new in text:
    text = text.replace(anchor_new, extern_block + anchor_new, 1)
    text = text.replace(lookup_anchor_new, lookup_anchor_new + call_block, 1)
else:
    # <4.17 fallback: hook the faccessat syscall definition directly.
    anchor_old = "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)"
    lookup_anchor_old = "unsigned int lookup_flags = LOOKUP_FOLLOW;"
    if anchor_old not in text or lookup_anchor_old not in text:
        sys.exit(1)
    text = text.replace(anchor_old, extern_block + anchor_old, 1)
    text = text.replace(lookup_anchor_old, lookup_anchor_old + call_block, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

# --- fs/read_write.c: vfs_read --------------------------------------------
apply_patch "fs/read_write.c" "ksu_handle_vfs_read" << 'PYEOF'
import sys
path = "fs/read_write.c"
with open(path) as f:
    text = f.read()

extern_anchor = "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "extern bool ksu_vfs_read_hook __read_mostly;\n"
    "extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n"
    "\t\t\tsize_t *count_ptr, loff_t **pos);\n"
    "#endif\n"
)
if extern_anchor not in text:
    sys.exit(1)
text = text.replace(extern_anchor, extern_block + extern_anchor, 1)

body_anchor = extern_anchor + "\n{\n\tssize_t ret;"
call_block = (
    "\n#ifdef CONFIG_KSU\n"
    "\tif (unlikely(ksu_vfs_read_hook))\n"
    "\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);\n"
    "#endif"
)
if body_anchor not in text:
    sys.exit(1)
text = text.replace(body_anchor, body_anchor + call_block, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

# --- fs/stat.c: vfs_statx (or vfs_fstatat fallback) -----------------------
apply_patch "fs/stat.c" "ksu_handle_stat" << 'PYEOF'
import sys
path = "fs/stat.c"
with open(path) as f:
    text = f.read()

extern_block_fn = lambda: (
    "#ifdef CONFIG_KSU\n"
    "extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n"
    "#endif\n\n"
)
call_block = (
    "\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_stat(&dfd, &filename, &flags);\n"
    "#endif"
)

anchor_new = "int vfs_statx(int dfd, const char __user *filename, int flags,"
body_marker_new = "unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;"
anchor_old = "int vfs_fstatat(int dfd, const char __user *filename, struct kstat *stat,"
body_marker_old = "unsigned int lookup_flags = 0;"

if anchor_new in text and body_marker_new in text:
    text = text.replace(anchor_new, extern_block_fn() + anchor_new, 1)
    text = text.replace(body_marker_new, body_marker_new + call_block, 1)
elif anchor_old in text and body_marker_old in text:
    call_block_old = call_block.replace("&flags", "&flag")
    text = text.replace(anchor_old, extern_block_fn() + anchor_old, 1)
    text = text.replace(body_marker_old, body_marker_old + call_block_old, 1)
else:
    sys.exit(1)

with open(path, "w") as f:
    f.write(text)
PYEOF

if [ "$FAILED" = "1" ]; then
  echo "::error::One or more manual-hook patches failed to apply — see errors above."
  exit 1
fi

# --- Safe Mode (drivers/input/input.c) — same feature, same symbols
# across KernelSU and its forks.
apply_patch "drivers/input/input.c" "ksu_handle_input_handle_event" << 'PYEOF'
import sys
path = "drivers/input/input.c"
with open(path) as f:
    text = f.read()

extern_anchor = "static void input_handle_event(struct input_dev *dev,"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "extern bool ksu_input_hook __read_mostly;\n"
    "extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n"
    "#endif\n\n"
)
if extern_anchor not in text:
    sys.exit(1)
text = text.replace(extern_anchor, extern_block + extern_anchor, 1)

call_anchor = "int disposition = input_get_disposition(dev, type, code, &value);"
call_block = (
    "\n#ifdef CONFIG_KSU\n"
    "\tif (unlikely(ksu_input_hook))\n"
    "\t\tksu_handle_input_handle_event(&type, &code, &value);\n"
    "#endif"
)
if call_anchor not in text:
    sys.exit(1)
text = text.replace(call_anchor, call_anchor + call_block, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

if [ "$FAILED" = "1" ]; then
  echo "::error::Safe Mode (input.c) or another patch failed — see errors above."
  exit 1
fi

echo "All upstream-lineage manual-hook patches applied successfully (4 syscall hooks + Safe Mode)."
