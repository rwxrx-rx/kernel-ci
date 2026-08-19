#!/usr/bin/env bash
# scripts/patch_ksu_manual_hooks.sh
# Applies KernelSU-Next's official 5-file manual (non-kprobe) hook
# integration, per:
# https://kernelsu-next.github.io/webpage/pages/how-to-integrate-for-non-gki.html
#
# Anchor-matched against stock function signatures rather than applying
# the raw unified diffs line-for-line, since those are much less likely
# to break on a vendor-modified tree (fs/exec.c etc. are core VFS files
# and usually stay close to upstream even on heavily customized MTK
# trees, but exact line numbers/context never do). Idempotent: each
# insertion is skipped if its call site is already present.
set -euo pipefail
: "${KERNEL_DIR:?}"
cd "$KERNEL_DIR"

python3 << 'PYEOF'
import re, sys

def patch_file(path, insertions):
    try:
        with open(path, 'r') as f:
            text = f.read()
    except FileNotFoundError:
        print(f"::warning::{path} not found in this tree — skipping its manual hook insertion.")
        return

    changed = False
    for marker, anchor_pattern, build_insertion in insertions:
        if marker in text:
            print(f"  {path}: '{marker.strip()[:40]}...' already present, skipping.")
            continue
        m = re.search(anchor_pattern, text)
        if not m:
            print(f"::warning::{path}: anchor not found for one insertion (pattern: {anchor_pattern[:60]}...). "
                  f"This file likely diverges from stock enough that you'll need to add this hook by hand — "
                  f"see the KernelSU-Next non-GKI guide.")
            continue
        insert_text = build_insertion(m)
        pos = m.end()
        text = text[:pos] + insert_text + text[pos:]
        changed = True
        print(f"  {path}: inserted '{marker.strip()[:40]}...'")

    if changed:
        with open(path, 'w') as f:
            f.write(text)

# --- fs/exec.c ---------------------------------------------------------
patch_file("fs/exec.c", [
    ("ksu_handle_execveat",
     r"\nint do_execve\(struct filename \*filename,",
     lambda m: "\n#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n\t\t\t\tvoid *argv, void *envp, int *flags);\n#endif\n" + m.group(0)[1:]
    ),
])
# Call site inside do_execve() — after its two user_arg_ptr locals.
def _insert_execve_call(text):
    marker = "ksu_handle_execveat((int *)AT_FDCWD"
    if marker in text:
        return text
    pat = re.compile(
        r"(struct user_arg_ptr argv = \{ \.ptr\.native = __argv \};\s*\n\s*struct user_arg_ptr envp = \{ \.ptr\.native = __envp \};\s*\n)"
    )
    def repl(m):
        return m.group(1) + "#ifdef CONFIG_KSU\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n"
    new_text, n = pat.subn(repl, text, count=1)
    if n == 0:
        print("::warning::fs/exec.c: do_execve() call-site anchor not found — extern was added (if matched above) but the actual hook call wasn't inserted. Add it by hand: ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0); right after the argv/envp locals in do_execve().")
    return new_text

try:
    with open("fs/exec.c") as f:
        t = f.read()
    t2 = _insert_execve_call(t)
    if t2 != t:
        with open("fs/exec.c", "w") as f:
            f.write(t2)
        print("  fs/exec.c: inserted do_execve() call site")
except FileNotFoundError:
    pass

# --- fs/open.c ----------------------------------------------------------
patch_file("fs/open.c", [
    ("ksu_handle_faccessat",
     r"\nSYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)",
     lambda m: "\n#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n\t\t\t\tint *mode, int *flags);\n#endif\n" + m.group(0)[1:]
    ),
])
def _insert_faccessat_call(text):
    marker = "ksu_handle_faccessat(&dfd"
    if marker in text:
        return text
    pat = re.compile(r"(unsigned int lookup_flags = LOOKUP_FOLLOW;\s*\n)")
    def repl(m):
        return m.group(1) + "\n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n"
    new_text, n = pat.subn(repl, text, count=1)
    if n == 0:
        print("::warning::fs/open.c: faccessat() call-site anchor not found — add by hand: ksu_handle_faccessat(&dfd, &filename, &mode, NULL); right after `unsigned int lookup_flags = LOOKUP_FOLLOW;`")
    return new_text
try:
    with open("fs/open.c") as f:
        t = f.read()
    t2 = _insert_faccessat_call(t)
    if t2 != t:
        with open("fs/open.c", "w") as f:
            f.write(t2)
        print("  fs/open.c: inserted faccessat() call site")
except FileNotFoundError:
    pass

# --- fs/read_write.c ------------------------------------------------------
patch_file("fs/read_write.c", [
    ("ksu_handle_sys_read",
     r"\nSYSCALL_DEFINE3\(read, unsigned int, fd, char __user \*, buf, size_t, count\)",
     lambda m: ("\n#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\n"
                "extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,\n"
                "\t\t\t\tchar __user **buf_ptr, size_t *count_ptr);\n#endif\n" + m.group(0)[1:])
    ),
])
def _insert_read_call(text):
    marker = "ksu_handle_sys_read(fd"
    if marker in text:
        return text
    pat = re.compile(r"(ssize_t ret = -EBADF;\s*\n)")
    def repl(m):
        return m.group(1) + "\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, &buf, &count);\n#endif\n"
    new_text, n = pat.subn(repl, text, count=1)
    if n == 0:
        print("::warning::fs/read_write.c: sys_read() call-site anchor not found — add by hand per the KernelSU-Next non-GKI guide.")
    return new_text
try:
    with open("fs/read_write.c") as f:
        t = f.read()
    t2 = _insert_read_call(t)
    if t2 != t:
        with open("fs/read_write.c", "w") as f:
            f.write(t2)
        print("  fs/read_write.c: inserted sys_read() call site")
except FileNotFoundError:
    pass

# --- fs/stat.c -----------------------------------------------------------
patch_file("fs/stat.c", [
    ("ksu_handle_stat",
     r"return cp_new_stat\(&stat, statbuf\);\s*\n\}\s*\n",
     lambda m: m.group(0) + "\n#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n\t\t\t\tint *flags);\n#endif\n"
    ),
])
def _insert_stat_call(text):
    marker = "ksu_handle_stat(&dfd"
    if marker in text:
        return text
    pat = re.compile(
        r"(SYSCALL_DEFINE4\(newfstatat, int, dfd, const char __user \*, filename,\s*\n\s*struct stat __user \*, statbuf, int, flag\)\s*\n\{\s*\n\s*struct kstat stat;\s*\n\s*int error;\s*\n)"
    )
    def repl(m):
        return m.group(1) + "\n#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n"
    new_text, n = pat.subn(repl, text, count=1)
    if n == 0:
        print("::warning::fs/stat.c: newfstatat() call-site anchor not found — add by hand per the KernelSU-Next non-GKI guide.")
    return new_text
try:
    with open("fs/stat.c") as f:
        t = f.read()
    t2 = _insert_stat_call(t)
    if t2 != t:
        with open("fs/stat.c", "w") as f:
            f.write(t2)
        print("  fs/stat.c: inserted newfstatat() call site")
except FileNotFoundError:
    pass

# --- kernel/reboot.c -------------------------------------------------------
patch_file("kernel/reboot.c", [
    ("ksu_handle_sys_reboot",
     r"\nSYSCALL_DEFINE4\(reboot, int, magic1, int, magic2, unsigned int, cmd,\s*\n\s*void __user \*, arg\)",
     lambda m: "\n#ifdef CONFIG_KSU\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n" + m.group(0)[1:]
    ),
])
def _insert_reboot_call(text):
    marker = "ksu_handle_sys_reboot(magic1"
    if marker in text:
        return text
    pat = re.compile(r"(int ret = 0;\s*\n)")
    def repl(m):
        return m.group(1) + "\n#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n"
    new_text, n = pat.subn(repl, text, count=1)
    if n == 0:
        print("::warning::kernel/reboot.c: reboot() call-site anchor not found — add by hand per the KernelSU-Next non-GKI guide.")
    return new_text
try:
    with open("kernel/reboot.c") as f:
        t = f.read()
    t2 = _insert_reboot_call(t)
    if t2 != t:
        with open("kernel/reboot.c", "w") as f:
            f.write(t2)
        print("  kernel/reboot.c: inserted reboot() call site")
except FileNotFoundError:
    pass

print("Manual hook patching pass finished — review ::warning:: lines above, if any, and add those call sites by hand.")
PYEOF
