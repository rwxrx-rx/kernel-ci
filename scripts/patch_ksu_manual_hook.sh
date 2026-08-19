#!/usr/bin/env bash
# scripts/patch_ksu_manual_hook.sh
#
# Applies KernelSU-Next's OFFICIAL manual-hook patch set (5 syscall
# files + Safe Mode), taken directly from:
# https://kernelsu-next.github.io/webpage/pages/how-to-integrate-for-non-gki.html
#
# BUG FIXED: earlier version used a plain whole-file
# `text.replace(anchor, ..., 1)` for the call-site insertion. Some of
# those anchor lines (e.g. "unsigned int lookup_flags = LOOKUP_FOLLOW;"
# in fs/open.c) aren't unique to the target function — they're a common
# local-variable-init pattern repeated across several functions in the
# same file. replace(..., 1) grabbed whichever occurrence came FIRST in
# the file, which was sometimes a different, earlier function — landing
# the call where dfd/filename/mode don't exist ("undeclared identifier")
# and, if that earlier spot was before the extern declaration too,
# "implicit declaration of function" as well. Every insertion below now
# searches for its call-site anchor starting AFTER the function
# signature it belongs to, so it can't grab an unrelated earlier match.
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
    echo "::error::Failed to patch $file — anchor line not found (or found in an unexpected place). This vendor tree's version of this file differs from stock 4.14; paste me the relevant function and I'll fix the anchor."
    FAILED=1
  fi
}

# Shared helper, prepended to every python heredoc below: inserts
# extern_block right before extern_anchor, then inserts call_block right
# after the FIRST call_anchor match found AFTER that point — never
# before it, so it can't land in an earlier, unrelated function.
PY_HELPER='
import sys

def patch_one(path, extern_anchor, extern_block, call_anchor, call_block, search_from=0):
    with open(path) as f:
        text = f.read()
    idx = text.find(extern_anchor, search_from)
    if idx == -1:
        sys.exit(1)
    text = text[:idx] + extern_block + text[idx:]
    search_start = idx + len(extern_block) + len(extern_anchor)
    call_idx = text.find(call_anchor, search_start)
    if call_idx == -1:
        sys.exit(1)
    insert_at = call_idx + len(call_anchor)
    text = text[:insert_at] + call_block + text[insert_at:]
    with open(path, "w") as f:
        f.write(text)
    return search_start  # caller can chain a second patch from here
'

# --- fs/exec.c ------------------------------------------------------------
apply_patch "fs/exec.c" "ksu_handle_execveat" << PYEOF
${PY_HELPER}

path = "fs/exec.c"

extern_anchor = "int do_execve(struct filename *filename,"
extern_block = (
    "#ifdef CONFIG_KSU\n"
    "__attribute__((hot))\n"
    "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
    "\t\t\t\tvoid *argv, void *envp, int *flags);\n"
    "#endif\n\n"
)
call_anchor_1 = "struct user_arg_ptr envp = { .ptr.native = __envp };"
call_block_1 = (
    "\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n"
    "#endif"
)
next_start = patch_one("fs/exec.c", extern_anchor, extern_block, call_anchor_1, call_block_1)

# Second call site (compat_do_execve) comes after do_execve in the file
# — search continues from where the first patch left off, so this can
# only match the *next* occurrence, not re-match the one just patched.
with open(path) as f:
    text = f.read()
call_anchor_2 = ".ptr.compat = __envp,\n\t};"
call_block_2 = (
    "\n#ifdef CONFIG_KSU // 32-bit ksud and 32-on-64 support\n"
    "\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n"
    "#endif"
)
call_idx = text.find(call_anchor_2, next_start)
if call_idx == -1:
    sys.exit(1)
insert_at = call_idx + len(call_anchor_2)
text = text[:insert_at] + call_block_2 + text[insert_at:]
with open(path, "w") as f:
    f.write(text)
PYEOF

# --- fs/open.c --------------------------------------------------------
apply_patch "fs/open.c" "ksu_handle_faccessat" << PYEOF
${PY_HELPER}
patch_one(
    "fs/open.c",
    "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)",
    "#ifdef CONFIG_KSU\n"
    "__attribute__((hot))\n"
    "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_ptr,\n"
    "\t\t\t\tint *mode, int *flags);\n"
    "#endif\n\n",
    "unsigned int lookup_flags = LOOKUP_FOLLOW;",
    "\n\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
    "#endif",
)
PYEOF

# --- fs/read_write.c --------------------------------------------------
apply_patch "fs/read_write.c" "ksu_handle_sys_read" << PYEOF
${PY_HELPER}
patch_one(
    "fs/read_write.c",
    "SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)",
    "#ifdef CONFIG_KSU\n"
    "extern bool ksu_vfs_read_hook __read_mostly;\n"
    "extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,\n"
    "\t\t\t\tchar __user **buf_ptr, size_t *count_ptr);\n"
    "#endif\n\n",
    "ssize_t ret = -EBADF;",
    "\n\n#ifdef CONFIG_KSU\n"
    "\tif (unlikely(ksu_vfs_read_hook))\n"
    "\t\tksu_handle_sys_read(fd, &buf, &count);\n"
    "#endif",
)
PYEOF

# --- fs/stat.c ------------------------------------------------------------
apply_patch "fs/stat.c" "ksu_handle_stat" << PYEOF
${PY_HELPER}
patch_one(
    "fs/stat.c",
    "SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,",
    "#ifdef CONFIG_KSU\n"
    "__attribute__((hot))\n"
    "extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n"
    "\t\t\t\tint *flags);\n"
    "#endif\n\n",
    "int error;",
    "\n\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_stat(&dfd, &filename, &flag);\n"
    "#endif",
)
PYEOF

# --- kernel/reboot.c --------------------------------------------------
apply_patch "kernel/reboot.c" "ksu_handle_sys_reboot" << PYEOF
${PY_HELPER}
patch_one(
    "kernel/reboot.c",
    "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,",
    "#ifdef CONFIG_KSU\n"
    "extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n"
    "#endif\n\n",
    "int ret = 0;",
    "\n\n#ifdef CONFIG_KSU\n"
    "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
    "#endif",
)
PYEOF

if [ "$FAILED" = "1" ]; then
  echo "::error::One or more manual-hook patches failed to apply — see errors above. Build will likely fail at link time again until these are fixed (either by hand, or by pasting me the actual surrounding code from the file(s) that failed so I can fix the anchor)."
  exit 1
fi

# --- Safe Mode (drivers/input/input.c) --------------------------------
apply_patch "drivers/input/input.c" "ksu_handle_input_handle_event" << PYEOF
${PY_HELPER}
patch_one(
    "drivers/input/input.c",
    "static void input_handle_event(struct input_dev *dev,",
    "#ifdef CONFIG_KSU\n"
    "extern bool ksu_input_hook __read_mostly;\n"
    "extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n"
    "#endif\n\n",
    "int disposition = input_get_disposition(dev, type, code, &value);",
    "\n#ifdef CONFIG_KSU\n"
    "\tif (unlikely(ksu_input_hook))\n"
    "\t\tksu_handle_input_handle_event(&type, &code, &value);\n"
    "#endif",
)
PYEOF

if [ "$FAILED" = "1" ]; then
  echo "::error::Safe Mode (input.c) or another patch failed — see errors above."
  exit 1
fi

echo "All manual-hook patches applied successfully (5 syscall hooks + Safe Mode)."
