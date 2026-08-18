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
    echo "==> Integrating KernelSU-Next (legacy / manual hook mode)"
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

# --- Manual (non-kprobe) hook, required by susfs4ksu on non-GKI kernels ---
# This kernel is 4.14 non-GKI: kprobe hooking is unreliable this old, so we
# force every *KernelSU-family* fork onto its manual-hook path the same way
# upstream KernelSU's own "non-GKI integration" guide does it — disable the
# CONFIG_KPROBES ifdef guards inside the KSU driver directory so it never
# tries to attach kprobes, and rely on the manual calls already added to
# fs/exec.c / fs/open.c / etc by run_setup() above (each setup.sh injects
# those call sites into the kernel tree itself, not just the driver dir).
if [ -d "$KSU_DIR" ]; then
  echo "==> Forcing manual hook mode in $KSU_DIR (disabling CONFIG_KPROBES paths)"
  # grep exits 1 (not an error — just "no matches") when this fork's
  # legacy branch already ships without any CONFIG_KPROBES ifdef guard
  # (i.e. it's manual-hook-only already). Under `set -e -o pipefail`
  # that 1 would otherwise kill the whole script here with no message,
  # so the `|| true` is required, not cosmetic.
  grep -rl '#ifdef CONFIG_KPROBES' "$KSU_DIR" 2>/dev/null | while read -r f; do
    sed -i 's/#ifdef CONFIG_KPROBES/#if defined(CONFIG_KPROBES) \&\& 0/' "$f"
  done || true
fi

# Make sure the defconfig actually enables KSU
if ! grep -q '^CONFIG_KSU=y' "arch/${ARCH}/configs/${DEFCONFIG}" 2>/dev/null; then
  echo "CONFIG_KSU=y" >> "arch/${ARCH}/configs/${DEFCONFIG}"
fi
