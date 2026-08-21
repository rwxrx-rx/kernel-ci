#!/usr/bin/env bash
# scripts/patch_ksu.sh
# Integrates whichever fork was picked in workflow_dispatch ($KSU_VARIANT).
#
# Rewritten against a proven reference build (same camellia/mt6833
# device, ReSukiSU + susfs v2.2.0 confirmed working end to end) rather
# than generic per-fork guesses. Confidence level differs by fork:
#   - kernelsu-next-legacy: verified working in THIS pipeline already
#     (5-file manual hook + Safe Mode, all clean) — untouched.
#   - resukisu: full proven logic ported from the reference, pinned to
#     an exact commit with fail-closed ABI/revision-count assertions.
#   - xxksu / sukisu-ultra: the reference itself only does generic
#     clone+symlink for these (no fork-specific compat patches), so
#     that's what we do too — less battle-tested than ReSukiSU, but not
#     a guess either.
set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${KSU_VARIANT:?KSU_VARIANT not set}"
: "${ARCH:?}"
: "${DEFCONFIG:?}"

cd "$KERNEL_DIR"
DEFCONFIG_PATH="arch/${ARCH}/configs/${DEFCONFIG}"

set_flags() {
  for flag in "$@"; do
    key="${flag%%=*}"
    grep -q "^${key}=" "$DEFCONFIG_PATH" 2>/dev/null && sed -i "/^${key}=/d" "$DEFCONFIG_PATH"
    echo "$flag" >> "$DEFCONFIG_PATH"
  done
}
unset_flag() {
  # Force a symbol OFF (as "# CONFIG_X is not set"), whatever state it's in.
  for key in "$@"; do
    sed -i "/^${key}=/d" "$DEFCONFIG_PATH" 2>/dev/null || true
    sed -i "/^# ${key} is not set/d" "$DEFCONFIG_PATH" 2>/dev/null || true
    echo "# ${key} is not set" >> "$DEFCONFIG_PATH"
  done
}
run_setup() {
  local url="$1" ref="$2"
  if [ -n "$ref" ]; then
    curl -LSs "$url" | bash -s "$ref"
  else
    curl -LSs "$url" | bash -
  fi
}

if [ "$KSU_VARIANT" = "none" ]; then
  echo "KSU_VARIANT=none — building a vanilla kernel, nothing to patch."
  exit 0
fi

case "$KSU_VARIANT" in
  # =====================================================================
  kernelsu-next-legacy)
    echo "==> Integrating KernelSU-Next (legacy)"
    run_setup "$KSUN_SETUP_URL" "$KSUN_REF"
    KSU_DIR="KernelSU-Next"
    echo "KSU_DIR=$KSU_DIR" >> "$GITHUB_ENV"

    # sulog/event.c compat fix — unrelated to hook mode, genuine
    # kernel-version mismatch (timespec64 vs the pre-Y2038 timespec this
    # 4.14 tree's get_monotonic_boottime() wrapper actually takes).
    # -L matters: drivers/kernelsu is a symlink into the real clone, and
    # plain `find` refuses to descend into a symlinked dir without it.
    for EVENT_C in $(find -L "$KERNEL_DIR" -type f -path "*/kernelsu*/event.c" 2>/dev/null); do
      echo "==> Fixing timespec64/boottime compat in $EVENT_C"
      sed -i 's/struct timespec64/struct timespec/g' "$EVENT_C"
      sed -i 's/ktime_get_boottime_ts64/get_monotonic_boottime/g' "$EVENT_C"
    done

    echo "==> Applying KernelSU-Next's manual-hook patch set (5 syscall files + Safe Mode)"
    bash "$(dirname "${BASH_SOURCE[0]}")/patch_ksu_manual_hook.sh"
    unset_flag CONFIG_KPROBES CONFIG_KPROBE_EVENTS
    set_flags CONFIG_MODULES=y CONFIG_KSU=y
    ;;

  # =====================================================================
  resukisu)
    echo "==> Integrating ReSukiSU (pinned commit, SUSFS Inline hooks)"
    : "${RESUKISU_REPO:?}" "${RESUKISU_BRANCH:?}" "${RESUKISU_PINNED_COMMIT:?}"
    : "${RESUKISU_EXPECTED_REV_COUNT:?}" "${RESUKISU_EXPECTED_ABI:?}"

    rm -rf drivers/kernelsu KernelSU KernelSU_temp
    if ! git clone --depth=1 -b "$RESUKISU_BRANCH" "$RESUKISU_REPO" KernelSU_temp 2>/dev/null; then
      git clone --depth=1 "$RESUKISU_REPO" KernelSU_temp
    fi
    # ReSukiSU derives its version from the full official git revision
    # count, so the shallow clone needs unshallowing before pinning.
    git -C KernelSU_temp fetch --unshallow origin "$RESUKISU_BRANCH"
    git -C KernelSU_temp fetch origin "$RESUKISU_PINNED_COMMIT"
    git -C KernelSU_temp checkout --detach "$RESUKISU_PINNED_COMMIT"
    [ "$(git -C KernelSU_temp rev-parse HEAD)" = "$RESUKISU_PINNED_COMMIT" ] || {
      echo "::error::ReSukiSU commit pin mismatch"; exit 1; }
    [ "$(git -C KernelSU_temp rev-parse --is-shallow-repository)" = "false" ] || {
      echo "::error::ReSukiSU repo still shallow after --unshallow"; exit 1; }
    ACTUAL_REV_COUNT="$(git -C KernelSU_temp rev-list --count HEAD)"
    [ "$ACTUAL_REV_COUNT" = "$RESUKISU_EXPECTED_REV_COUNT" ] || {
      echo "::error::ReSukiSU rev-count mismatch: got $ACTUAL_REV_COUNT, expected $RESUKISU_EXPECTED_REV_COUNT (repo history changed upstream? re-derive the pin)"; exit 1; }
    [ "$((30000 + ACTUAL_REV_COUNT + 700))" = "$RESUKISU_EXPECTED_ABI" ] || {
      echo "::error::ReSukiSU ABI derivation mismatch"; exit 1; }

    mkdir -p drivers/kernelsu
    if [ -d "KernelSU_temp/kernel" ]; then
      rm -rf drivers/kernelsu
      ln -s ../KernelSU_temp/kernel drivers/kernelsu
    elif [ -f "KernelSU_temp/Makefile" ]; then
      rm -rf drivers/kernelsu
      ln -s ../KernelSU_temp drivers/kernelsu
    else
      echo "::error::No Makefile found in cloned ReSukiSU repository"
      exit 1
    fi
    KSU_DIR="KernelSU_temp"
    echo "KSU_DIR=$KSU_DIR" >> "$GITHUB_ENV"
    echo "ReSukiSU pinned commit: $RESUKISU_PINNED_COMMIT (rev-count $ACTUAL_REV_COUNT, ABI $RESUKISU_EXPECTED_ABI)"

    # UAPI header sync
    mkdir -p drivers/kernelsu/uapi drivers/kernelsu/policy/uapi include/uapi
    find KernelSU_temp/ drivers/kernelsu/ -type d -name "uapi" 2>/dev/null | while read -r ufolder; do
      cp -rf "$ufolder"/* drivers/kernelsu/uapi/ 2>/dev/null || true
      cp -rf "$ufolder"/* drivers/kernelsu/policy/uapi/ 2>/dev/null || true
      cp -rf "$ufolder"/* include/uapi/ 2>/dev/null || true
    done

    # Pin the built-in kernel ABI to match the official manager build.
    KSU_ABI_VERSION="$RESUKISU_EXPECTED_ABI"
    if [ -f "drivers/kernelsu/Kbuild" ]; then
      sed -i '/-DKERNEL_SU_VERSION=/d' drivers/kernelsu/Kbuild
      sed -i "1iccflags-y += -I\$(srctree)/drivers/kernelsu -I\$(srctree)/drivers/kernelsu/include -DKERNEL_SU_VERSION=$KSU_ABI_VERSION" drivers/kernelsu/Kbuild
      sed -i -E "s/^[[:space:]]*KSU_VERSION[[:space:]]*:=.*/KSU_VERSION := $KSU_ABI_VERSION/" drivers/kernelsu/Kbuild
      printf '%s\n' "ccflags-y += -DKSU_VERSION=$KSU_ABI_VERSION -DKERNEL_SU_VERSION=$KSU_ABI_VERSION" >> drivers/kernelsu/Kbuild
    fi
    if [ -f "drivers/kernelsu/Makefile" ]; then
      sed -i '/-DKERNEL_SU_VERSION=/d' drivers/kernelsu/Makefile
      sed -i "1iccflags-y += -I\$(srctree)/drivers/kernelsu -I\$(srctree)/drivers/kernelsu/include -DKERNEL_SU_VERSION=$KSU_ABI_VERSION" drivers/kernelsu/Makefile
      sed -i -E "s/^[[:space:]]*KSU_VERSION[[:space:]]*:=.*/KSU_VERSION := $KSU_ABI_VERSION/" drivers/kernelsu/Makefile
    fi

    # ksu_cred extern injection (precise: only files that use it but
    # don't already declare/define it)
    find drivers/kernelsu/ -type f -name "*.c" | while read -r file; do
      if grep -q "ksu_cred" "$file" && ! grep -q "struct cred \*ksu_cred" "$file" && ! grep -q "extern.*ksu_cred" "$file"; then
        sed -i '1istruct cred;\nextern struct cred *ksu_cred;' "$file"
      fi
    done

    # selinux_hide.c missing identifiers
    SELINUX_HIDE_FILE="drivers/kernelsu/feature/selinux_hide.c"
    if [ -f "$SELINUX_HIDE_FILE" ]; then
      sed -i '1i#include <linux/types.h>\nstruct policydb;\nstruct sidtab;\nextern struct policydb *backup_policydb;\nextern struct sidtab *backup_sidtab;\nextern bool ksu_late_loaded;' "$SELINUX_HIDE_FILE"
      if ! grep -q "^struct policydb \*backup_policydb" "$SELINUX_HIDE_FILE" && ! grep -rq "struct policydb \*backup_policydb" drivers/kernelsu/selinux/ 2>/dev/null; then
        echo "struct policydb *backup_policydb = NULL;" >> "$SELINUX_HIDE_FILE"
        echo "struct sidtab *backup_sidtab = NULL;" >> "$SELINUX_HIDE_FILE"
      fi
      if ! grep -rq "ksu_late_loaded" drivers/kernelsu/core/ 2>/dev/null; then
        echo "bool ksu_late_loaded = false;" >> "$SELINUX_HIDE_FILE"
      fi
    fi

    # ksud_integration.c missing identifiers + bootstrap install rc
    KSUD_FILE="drivers/kernelsu/runtime/ksud_integration.c"
    if [ -f "$KSUD_FILE" ]; then
      python3 "$(dirname "${BASH_SOURCE[0]}")/resukisu_helpers/add_ksud_install_rc.py" "$KSUD_FILE"
      sed -i '1i#include <linux/types.h>\nextern bool ksu_no_custom_rc;\nextern bool ksu_late_loaded;' "$KSUD_FILE"
      grep -rq "bool ksu_no_custom_rc" drivers/kernelsu/ 2>/dev/null || echo "bool ksu_no_custom_rc = false;" >> "$KSUD_FILE"
      grep -rq "bool ksu_late_loaded" drivers/kernelsu/ 2>/dev/null || echo "bool ksu_late_loaded = false;" >> "$KSUD_FILE"
    fi

    # supercall.c SUSFS_MAGIC
    SUPERCALL_FILE="drivers/kernelsu/supercall/supercall.c"
    if [ -f "$SUPERCALL_FILE" ]; then
      sed -i '1i#include <linux/types.h>\n#include <linux/susfs_def.h>\n#ifndef SUSFS_MAGIC\n#define SUSFS_MAGIC 0xA5A5A5A5\n#endif' "$SUPERCALL_FILE"
    fi
    DISPATCH_FILE="drivers/kernelsu/supercall/dispatch.c"
    if [ -f "$DISPATCH_FILE" ]; then
      sed -i "1i__attribute__((used, section(\".rodata\"))) static const unsigned int resukisu_kernel_abi_version = $KSU_ABI_VERSION;\n#include <linux/types.h>\n#include <linux/susfs_def.h>\n#ifndef KERNEL_SU_VERSION\n#define KERNEL_SU_VERSION $KSU_ABI_VERSION\n#endif\nextern bool ksu_late_loaded;" "$DISPATCH_FILE"
    fi
    rm -f drivers/kernelsu/include/linux/susfs_def.h

    sed -i 's|source "KernelSU/Kconfig"|source "drivers/kernelsu/Kconfig"|g' drivers/Kconfig
    sed -i 's|source "drivers/KernelSU/Kconfig"|source "drivers/kernelsu/Kconfig"|g' drivers/Kconfig
    grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig || \
      { sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig || echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig; }
    grep -q "kernelsu" drivers/Makefile || echo 'obj-y += kernelsu/' >> drivers/Makefile

    # SUSFS Inline hook mode: NOT manual, NOT tracepoint — KSU_SUSFS
    # selected instead (finalized properly after susfs tree is
    # installed by patch_susfs.sh, this is the pre-susfs baseline).
    unset_flag CONFIG_KSU_MANUAL_HOOK CONFIG_KSU_TRACEPOINT_HOOK CONFIG_KPROBES CONFIG_KPROBE_EVENTS
    set_flags CONFIG_KSU=y CONFIG_KSU_SUSFS=y

    # ReSukiSU's static_export_check.mk hard-fails the build unless
    # either CONFIG_KALLSYMS_ALL is on or write_op is exported from the
    # vendor's security/selinux/selinuxfs.c. We don't have that vendor
    # file in this overlay, so satisfy it the simple way instead.
    set_flags CONFIG_KALLSYMS_ALL=y

    echo "ReSukiSU integration done — SUSFS Inline hook mode staged (finalized in patch_susfs.sh)."
    ;;

  # =====================================================================
  xxksu|sukisu-ultra)
    if [ "$KSU_VARIANT" = "xxksu" ]; then
      REPO="$XXKSU_REPO"; BRANCH="$XXKSU_BRANCH"
    else
      REPO="$SUKISU_REPO"; BRANCH="$SUKISU_BRANCH"
    fi
    echo "==> Integrating $KSU_VARIANT ($REPO @ $BRANCH) — generic clone+symlink"
    echo "    (no fork-specific compat patches for this one yet — less"
    echo "    battle-tested than ReSukiSU/KernelSU-Next. If the build"
    echo "    fails, paste the error and I'll add whatever this fork"
    echo "    specifically needs, same as the others.)"

    rm -rf drivers/kernelsu KernelSU KernelSU_temp
    if ! git clone --depth=1 -b "$BRANCH" "$REPO" KernelSU_temp 2>/dev/null; then
      git clone --depth=1 "$REPO" KernelSU_temp
    fi
    mkdir -p drivers/kernelsu
    if [ -d "KernelSU_temp/kernel" ]; then
      rm -rf drivers/kernelsu
      ln -s ../KernelSU_temp/kernel drivers/kernelsu
    elif [ -f "KernelSU_temp/Makefile" ]; then
      rm -rf drivers/kernelsu
      ln -s ../KernelSU_temp drivers/kernelsu
    else
      echo "::error::No Makefile found in cloned $KSU_VARIANT repository"
      exit 1
    fi
    KSU_DIR="KernelSU_temp"
    echo "KSU_DIR=$KSU_DIR" >> "$GITHUB_ENV"

    sed -i 's|source "KernelSU/Kconfig"|source "drivers/kernelsu/Kconfig"|g' drivers/Kconfig
    sed -i 's|source "drivers/KernelSU/Kconfig"|source "drivers/kernelsu/Kconfig"|g' drivers/Kconfig
    grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig || \
      { sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig || echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig; }
    grep -q "kernelsu" drivers/Makefile || echo 'obj-y += kernelsu/' >> drivers/Makefile

    # Kprobes stays on for these two — no verified manual/inline hook
    # path for either yet, and kprobes is the safe documented default.
    set_flags CONFIG_KSU=y CONFIG_KPROBES=y CONFIG_KPROBE_EVENTS=y CONFIG_MODULES=y
    ;;

  *)
    echo "::error::Unknown KSU_VARIANT '$KSU_VARIANT'. Valid: none, kernelsu-next-legacy, resukisu, xxksu, sukisu-ultra"
    exit 1
    ;;
esac
