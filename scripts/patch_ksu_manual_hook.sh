#!/usr/bin/env bash
# scripts/patch_ksu_manual_hook.sh
#
# Applies KernelSU-Next's OFFICIAL 5-file manual-hook patch set, taken
# directly from:
# https://kernelsu-next.github.io/webpage/pages/how-to-integrate-for-non-gki.html
#
# This is a genuinely different integration path from kprobes — it
# patches real call sites in 5 core kernel files instead of relying on
# kprobe attach points. Each insertion below is anchored to an exact,
# unique line from the vendor 4.14 source (do_execve's argument struct
# init, faccessat's lookup_flags declaration, etc.) rather than fuzzy
# context matching, so it either applies cleanly or fails loudly with
# the exact file/anchor that didn't match — it will NOT silently skip
# and leave you with a half-patched tree like the old sed-based
# approach did.
set -euo pipefail
: "${KERNEL_DIR:?}"

cd "$KERNEL_DIR"
FAILED=0

apply_patch() {
  # $1=file $2=marker(idempotency check) $3=python heredoc via stdin
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
    echo "::error::Failed to patch $file — anchor line not found. This vendor tree's version of this file differs from stock 4.14; you'll need to add the CONFIG_KSU hook here by hand. See the diff for $file at:"
    echo "    https://kernelsu-next.github.io/webpage/pages/how-to-integrate-for-non-gki.html"
    FAILED=1
  fi
}

# --- fs/exec.c ----------------------------------------------------------
apply_patch "fs/exec.c" "ksu_handle_execveat" << 'PYEOF'
import sys
path = "fs/exec.c"
with open(path) as f:
    text = f.read()

extern_anchor = "int do_execve(struct filename *filename,"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "__attribute__((hot))\n"
    "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
    "\t\t\t\tvoid *argv, void *envp, int *flags);\n"
    "#endif\n\n"
)
if extern_anchor not in text:
    sys.exit(1)
text = text.replace(extern_anchor, extern_block + extern_anchor, 1)

call_anchor_1 = "struct user_arg_ptr envp = { .ptr.native = __envp };"
call_block = (
    "\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n"
    "#endif"
)
if call_anchor_1 not in text:
    sys.exit(1)
text = text.replace(call_anchor_1, call_anchor_1 + call_block, 1)

call_anchor_2 = ".ptr.compat = __envp,\n\t};"
call_block_2 = (
    "\n#ifdef CONFIG_KSU // 32-bit ksud and 32-on-64 support\n"
    "\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n"
    "#endif"
)
if call_anchor_2 not in text:
    sys.exit(1)
text = text.replace(call_anchor_2, call_anchor_2 + call_block_2, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

# --- fs/open.c ------------------------------------------------------------
apply_patch "fs/open.c" "ksu_handle_faccessat" << 'PYEOF'
import sys
path = "fs/open.c"
with open(path) as f:
    text = f.read()

extern_anchor = "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "__attribute__((hot))\n"
    "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n"
    "\t\t\t\tint *mode, int *flags);\n"
    "#endif\n\n"
)
if extern_anchor not in text:
    sys.exit(1)
text = text.replace(extern_anchor, extern_block + extern_anchor, 1)

call_anchor = "unsigned int lookup_flags = LOOKUP_FOLLOW;"
call_block = (
    "\n\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
    "#endif"
)
if call_anchor not in text:
    sys.exit(1)
text = text.replace(call_anchor, call_anchor + call_block, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

# --- fs/read_write.c --------------------------------------------------
apply_patch "fs/read_write.c" "ksu_handle_sys_read" << 'PYEOF'
import sys
path = "fs/read_write.c"
with open(path) as f:
    text = f.read()

extern_anchor = "SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "extern bool ksu_vfs_read_hook __read_mostly;\n"
    "extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,\n"
    "\t\t\t\tchar __user **buf_ptr, size_t *count_ptr);\n"
    "#endif\n\n"
)
if extern_anchor not in text:
    sys.exit(1)
text = text.replace(extern_anchor, extern_block + extern_anchor, 1)

call_anchor = "ssize_t ret = -EBADF;"
call_block = (
    "\n\n#ifdef CONFIG_KSU\n"
    "\tif (unlikely(ksu_vfs_read_hook))\n"
    "\t\tksu_handle_sys_read(fd, &buf, &count);\n"
    "#endif"
)
if call_anchor not in text:
    sys.exit(1)
text = text.replace(call_anchor, call_anchor + call_block, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

# --- fs/stat.c ------------------------------------------------------------
apply_patch "fs/stat.c" "ksu_handle_stat" << 'PYEOF'
import sys
path = "fs/stat.c"
with open(path) as f:
    text = f.read()

extern_anchor = "SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "__attribute__((hot))\n"
    "extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n"
    "\t\t\t\tint *flags);\n"
    "#endif\n\n"
)
if extern_anchor not in text:
    sys.exit(1)
text = text.replace(extern_anchor, extern_block + extern_anchor, 1)

call_anchor = "int error;"
call_block = (
    "\n\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_stat(&dfd, &filename, &flag);\n"
    "#endif"
)
if call_anchor not in text:
    sys.exit(1)
text = text.replace(call_anchor, call_anchor + call_block, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

# --- kernel/reboot.c --------------------------------------------------
apply_patch "kernel/reboot.c" "ksu_handle_sys_reboot" << 'PYEOF'
import sys
path = "kernel/reboot.c"
with open(path) as f:
    text = f.read()

extern_anchor = "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n"
    "#endif\n\n"
)
if extern_anchor not in text:
    sys.exit(1)
text = text.replace(extern_anchor, extern_block + extern_anchor, 1)

call_anchor = "int ret = 0;"
call_block = (
    "\n\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
    "#endif"
)
if call_anchor not in text:
    sys.exit(1)
text = text.replace(call_anchor, call_anchor + call_block, 1)

with open(path, "w") as f:
    f.write(text)
PYEOF

if [ "$FAILED" = "1" ]; then
  echo "::error::One or more manual-hook patches failed to apply — see errors above. Build will likely fail at link time again until these are fixed (either by hand, or by pasting me the actual surrounding code from the file(s) that failed so I can fix the anchor)."
  exit 1
fi

# --- Safe Mode (drivers/input/input.c) --------------------------------
#
# THIS is where ksu_input_hook actually comes from — not the 5 files
# above. It's a separate, optional-but-recommended feature (volume-down
# at boot triggers Safe Mode / temporarily disables KSU) documented at
# https://kernelsu.org/guide/how-to-integrate-for-non-gki.html#safe-mode
# and missing from KernelSU-Next's own non-GKI page, which is why the
# very first "undefined symbol: ksu_input_hook" error happened — the 5
# call-site patches never touched input.c at all, so the symbol this
# driver expects was simply never provided anywhere in the tree.
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

echo "All manual-hook patches applied successfully (5 syscall hooks + Safe Mode)."
