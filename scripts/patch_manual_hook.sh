#!/usr/bin/env bash
set -euo pipefail

: "${KERNEL_DIR:?}"

echo "==> [Manual Hook] Starting code injection into core kernel..."

# Helper function for safe injection (Idempotent)
inject_hook() {
    local file="$1"
    local func_sig="$2"
    local extern_decl="$3"
    local hook_call="$4"

    if [ ! -f "$file" ]; then
        echo "[-] $file not found, skipping..."
        return
    fi

    if grep -q "CONFIG_KSU" "$file"; then
        echo "[~] $file is already injected with KSU, skipping..."
        return
    fi

    echo "[+] Injecting hook into $file..."

    # 1. Inject extern declaration at the top of the file (after #include lines)
    sed -i "/#include <linux\/fs.h>/a \\
/* KernelSU Manual Hook */\\
#ifdef CONFIG_KSU\\
$extern_decl\\
#endif\\
" "$file"

    # 2. Inject call site right below the target function declaration
    # FIXED: using index($0, sig) instead of regex matching ($0 ~ sig) to prevent Unmatched '(' errors
    awk -v sig="$func_sig" -v hook="\\n#ifdef CONFIG_KSU\\n$hook_call\\n#endif\\n" '
    BEGIN { inj=0; brace=0; }
    index($0, sig) > 0 { inj=1; }
    inj==1 && /{/ {
        print $0;
        print hook;
        inj=2;
        next;
    }
    { print $0; }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# --- 1. fs/exec.c (do_execveat_common / do_execve) ---
inject_hook \
    "$KERNEL_DIR/fs/exec.c" \
    "static int do_execveat_common" \
    "extern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *ptr, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *ptr, int *flags);" \
    "    if (unlikely(ksu_execveat_hook)) {\n        ksu_handle_execveat(&fd, &filename, &argv, &flags);\n    } else {\n        ksu_handle_execveat_sucompat(&fd, &filename, &argv, &flags);\n    }"

# --- 2. fs/open.c (faccessat) ---
inject_hook \
    "$KERNEL_DIR/fs/open.c" \
    "SYSCALL_DEFINE3(faccessat" \
    "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);" \
    "    ksu_handle_faccessat(&dfd, &filename, &mode, NULL);"

# --- 3. fs/read_write.c (vfs_read) ---
inject_hook \
    "$KERNEL_DIR/fs/read_write.c" \
    "ssize_t vfs_read(struct file " \
    "extern bool ksu_vfs_read_hook __read_mostly;\nextern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr, size_t *count_ptr, loff_t **pos);" \
    "    if (unlikely(ksu_vfs_read_hook)) {\n        ksu_handle_vfs_read(&file, &buf, &count, &pos);\n    }"

# --- 4. fs/stat.c (vfs_statx) ---
inject_hook \
    "$KERNEL_DIR/fs/stat.c" \
    "int vfs_statx(int dfd" \
    "extern bool ksu_vfs_statx_hook __read_mostly;\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);" \
    "    if (unlikely(ksu_vfs_statx_hook)) {\n        ksu_handle_stat(&dfd, &filename, &flags);\n    }"

# --- 5. kernel/reboot.c (sys_reboot) ---
inject_hook \
    "$KERNEL_DIR/kernel/reboot.c" \
    "SYSCALL_DEFINE4(reboot" \
    "extern int ksu_handle_reboot(int *magic1, int *magic2, unsigned int *cmd, void __user **arg);" \
    "    ksu_handle_reboot(&magic1, &magic2, &cmd, &arg);"

# --- 6. (Bonus KSU-Next) drivers/input/input.c (Volume Keys) ---
inject_hook \
    "$KERNEL_DIR/drivers/input/input.c" \
    "static void input_handle_event" \
    "extern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);" \
    "    if (unlikely(ksu_input_hook)) {\n        ksu_handle_input_handle_event(&type, &code, &value);\n    }"

echo "==> [Manual Hook] Integration complete."
