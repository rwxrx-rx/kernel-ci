#!/usr/bin/env bash
# scripts/patch_ksu.sh
# Integrates whichever fork was picked in workflow_dispatch ($KSU_VARIANT)
# into $KERNEL_DIR. All manifest values (KSUN_*, RESUKISU_*, ...) are
# already exported into the environment by clone-patch/action.yml.
set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${KSU_VARIANT:?KSU_VARIANT not set}"

cd "$KERNEL_DIR"

run_setup() {
  local url="$1" ref="$2"
  if [ -n "$ref" ]; then
    curl -LSs "$url" | bash -s "$ref"
  else
    curl -LSs "$url" | bash -
  fi
}

case "$KSU_VARIANT" in
  none)
    echo "KSU_VARIANT=none — building a vanilla kernel, nothing to patch."
    exit 0
    ;;
  kernelsu-next-legacy)
    echo "==> Integrating KernelSU-Next (legacy)"
    run_setup "$KSUN_SETUP_URL" "$KSUN_REF"
    KSU_DIR="KernelSU-Next"
    ;;
  resukisu)
    echo "==> Integrating ReSukiSU"
    run_setup "$RESUKISU_SETUP_URL" "$RESUKISU_REF"
    KSU_DIR="KernelSU"
    ;;
  xxksu)
    echo "==> Integrating xxKSU"
    if [[ "$XXKSU_SETUP_URL" == *CHANGE-ME* ]]; then
      echo "::error::manifest/ksu-variants.env still has the xxKSU placeholder URL. Fill in XXKSU_SETUP_URL/XXKSU_REF before selecting this variant."
      exit 1
    fi
    run_setup "$XXKSU_SETUP_URL" "$XXKSU_REF"
    KSU_DIR="KernelSU"
    ;;
  sukisu-ultra)
    echo "==> Integrating SukiSU Ultra ($SUKISU_REF branch)"
    run_setup "$SUKISU_SETUP_URL" "$SUKISU_REF"
    KSU_DIR="KernelSU"
    ;;
  wildksu)
    echo "==> Integrating Wild KSU (WildKernels)"
    run_setup "$WILDKSU_SETUP_URL" "$WILDKSU_REF"
    KSU_DIR="KernelSU"
    ;;
  *)
    echo "::error::Unknown KSU_VARIANT '$KSU_VARIANT'. Valid: none, kernelsu-next-legacy, resukisu, xxksu, sukisu-ultra, wildksu"
    exit 1
    ;;
esac

echo "KSU_DIR=$KSU_DIR" >> "$GITHUB_ENV"

# --- sulog/event.c compat fix (timespec64 vs timespec) -----------------
#
# Unrelated to hook mode — this is a genuine kernel-version mismatch:
# KernelSU-Next's "sulog" usage-logging feature calls
# ktime_get_boottime_ts64() with a `struct timespec64`, but on this old
# non-GKI 4.14 tree the available compat wrapper is the pre-Y2038
# get_monotonic_boottime(struct timespec *) — the 64-bit-safe timespec64
# API these files assume simply doesn't exist here. Confirmed by an
# actual compile error (not a guess this time):
#   event.c:62: incompatible pointer types passing 'struct timespec64 *'
#   to parameter of type 'struct timespec *'
# `-L` matters here for the same reason as everywhere else in this
# pipeline: $KSU_DIR is reached through a symlink (drivers/kernelsu ->
# the real clone), and plain `find` refuses to descend into a symlinked
# directory without it.
for EVENT_C in $(find -L "$KERNEL_DIR" -type f -path "*/kernelsu*/event.c" 2>/dev/null); do
  echo "==> Fixing timespec64/boottime compat in $EVENT_C"
  sed -i 's/struct timespec64/struct timespec/g' "$EVENT_C"
  sed -i 's/ktime_get_boottime_ts64/get_monotonic_boottime/g' "$EVENT_C"
done

# --- Hook mode ---------------------------------------------------------
#
# REMOVED (for good): an earlier version of this script tried to "force
# manual hook mode" by sed-disabling every `#ifdef CONFIG_KPROBES` block
# it could find inside $KSU_DIR. That never touched the real switch
# (CONFIG_KSU_KPROBE_HOOKS) and left a broken half-patched hybrid build.
#
# Manual hook is now done properly, via each fork's actual documented
# call-site API — which turned out to differ by lineage:
#   - kernelsu-next-legacy: KernelSU-Next's own API (do_execve, a
#     reboot.c hook it added itself, etc) — patch_ksu_manual_hook.sh
#     https://kernelsu-next.github.io/webpage/pages/how-to-integrate-for-non-gki.html
#   - resukisu / sukisu-ultra / wildksu: all forked from the ORIGINAL
#     tiann/KernelSU, which uses different function names entirely
#     (do_execveat_common, vfs_read, vfs_statx) —
#     patch_ksu_manual_hook_upstream.sh
#     https://kernelsu.org/guide/how-to-integrate-for-non-gki.html
#   - xxksu: no verified manual-hook doc found for this one — stays on
#     kprobes until you point me at its actual integration guide.
#
# Both manual-hook scripts also patch drivers/input/input.c (Safe Mode)
# — that's genuinely where `ksu_input_hook` comes from, a separate
# feature from the syscall hooks, missing from KernelSU-Next's own
# non-GKI page entirely (which is why the very first attempt at this
# undefined the symbol: the 5 syscall patches never touch input.c).
# The official guide is explicit that CONFIG_KPROBES must be OFF when
# using manual integration, or Safe Mode can false-trigger on a
# volume-down press at boot — so it's disabled outright below, not just
# left unset.
DEFCONFIG_PATH="arch/${ARCH}/configs/${DEFCONFIG}"
disable_kprobes() {
  grep -q '^CONFIG_KPROBES=y' "$DEFCONFIG_PATH" 2>/dev/null && sed -i '/^CONFIG_KPROBES=y/d' "$DEFCONFIG_PATH"
  grep -q '^# CONFIG_KPROBES is not set' "$DEFCONFIG_PATH" 2>/dev/null || echo '# CONFIG_KPROBES is not set' >> "$DEFCONFIG_PATH"
}
set_flags() {
  for flag in "$@"; do
    key="${flag%%=*}"
    grep -q "^${key}=" "$DEFCONFIG_PATH" 2>/dev/null && sed -i "/^${key}=/d" "$DEFCONFIG_PATH"
    echo "$flag" >> "$DEFCONFIG_PATH"
  done
}

case "$KSU_VARIANT" in
  kernelsu-next-legacy)
    echo "==> Applying KernelSU-Next's manual-hook patch set (5 syscall files + Safe Mode)"
    bash "$(dirname "${BASH_SOURCE[0]}")/patch_ksu_manual_hook.sh"
    disable_kprobes
    set_flags CONFIG_MODULES=y
    ;;
  resukisu|sukisu-ultra|wildksu)
    echo "==> Applying upstream-KernelSU-lineage manual-hook patch set for $KSU_VARIANT (4 syscall files + Safe Mode)"
    bash "$(dirname "${BASH_SOURCE[0]}")/patch_ksu_manual_hook_upstream.sh"
    disable_kprobes
    set_flags CONFIG_MODULES=y
    ;;
  xxksu)
    echo "==> Enabling kprobe-based hooks for xxKSU (no verified manual-hook patch set for this fork yet — tell me its integration doc and I'll wire manual mode in)"
    set_flags CONFIG_KPROBES=y CONFIG_KPROBE_EVENTS=y CONFIG_KSU_KPROBE_HOOKS=y CONFIG_MODULES=y
    ;;
esac

# Make sure the defconfig actually enables KSU
if ! grep -q '^CONFIG_KSU=y' "arch/${ARCH}/configs/${DEFCONFIG}" 2>/dev/null; then
  echo "CONFIG_KSU=y" >> "arch/${ARCH}/configs/${DEFCONFIG}"
fi
