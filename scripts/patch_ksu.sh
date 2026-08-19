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

# --- Hook mode ---------------------------------------------------------
#
# REMOVED (for good): an earlier version of this script tried to "force
# manual hook mode" by sed-disabling every `#ifdef CONFIG_KPROBES` block
# it could find inside $KSU_DIR. That never touched the real switch
# (CONFIG_KSU_KPROBE_HOOKS) and left a broken half-patched hybrid build.
#
# Manual hook mode is now done properly: the 5 official upstream patches
# (fs/exec.c, fs/open.c, fs/read_write.c, fs/stat.c, kernel/reboot.c)
# from KernelSU-Next's own non-GKI integration guide —
# https://kernelsu-next.github.io/webpage/pages/how-to-integrate-for-non-gki.html
# — applied via scripts/patch_ksu_manual_hook.sh, with CONFIG_KSU_KPROBE_HOOKS
# left OFF so the driver doesn't also try to install kprobes.
#
# Only wired up for kernelsu-next-legacy right now — it's the only fork
# whose manual-hook patch set I've actually verified against an
# authoritative source. The other forks (ReSukiSU, SukiSU Ultra, Wild
# KSU, xxKSU) may need their own equivalent patches; tell me which one
# you want and I'll look up its real integration doc before wiring it
# in, rather than guessing.
DEFCONFIG_PATH="arch/${ARCH}/configs/${DEFCONFIG}"
if [ "$KSU_VARIANT" = "kernelsu-next-legacy" ]; then
  echo "==> Applying KernelSU-Next's official manual-hook patch set (5 files)"
  bash "$(dirname "${BASH_SOURCE[0]}")/patch_ksu_manual_hook.sh"

  for flag in CONFIG_MODULES=y; do
    key="${flag%%=*}"
    grep -q "^${key}=" "$DEFCONFIG_PATH" 2>/dev/null && sed -i "/^${key}=/d" "$DEFCONFIG_PATH"
    echo "$flag" >> "$DEFCONFIG_PATH"
  done
  # Deliberately NOT setting CONFIG_KSU_KPROBE_HOOKS=y here — leaving it
  # unset is what tells KernelSU-Next to use the manually-patched call
  # sites above instead of installing kprobes.
elif [ "$KSU_VARIANT" != "none" ]; then
  echo "==> Enabling kprobe-based hooks for $KSU_VARIANT (no verified manual-hook patch set for this fork yet)"
  for flag in CONFIG_KPROBES=y CONFIG_KPROBE_EVENTS=y CONFIG_KSU_KPROBE_HOOKS=y CONFIG_MODULES=y; do
    key="${flag%%=*}"
    grep -q "^${key}=" "$DEFCONFIG_PATH" 2>/dev/null && sed -i "/^${key}=/d" "$DEFCONFIG_PATH"
    echo "$flag" >> "$DEFCONFIG_PATH"
  done
fi

# Make sure the defconfig actually enables KSU
if ! grep -q '^CONFIG_KSU=y' "arch/${ARCH}/configs/${DEFCONFIG}" 2>/dev/null; then
  echo "CONFIG_KSU=y" >> "arch/${ARCH}/configs/${DEFCONFIG}"
fi
