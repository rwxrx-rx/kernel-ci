#!/usr/bin/env bash
# scripts/patch_ksu.sh
set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${KSU_VARIANT:?KSU_VARIANT not set}"
: "${ARCH:?ARCH not set}"
: "${DEFCONFIG:?DEFCONFIG not set}"

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

DEFCONFIG_PATH="arch/${ARCH}/configs/${DEFCONFIG}"

echo "==> Configuring defconfig for Manual Hook Mode..."
if ! grep -q '^CONFIG_KSU=y' "$DEFCONFIG_PATH" 2>/dev/null; then
  echo "CONFIG_KSU=y" >> "$DEFCONFIG_PATH"
fi

sed -i '/^CONFIG_KSU_KPROBE_HOOKS=/d' "$DEFCONFIG_PATH" 2>/dev/null || true
echo "CONFIG_KSU_KPROBE_HOOKS=n" >> "$DEFCONFIG_PATH"

sed -i '/^CONFIG_KSU_WITH_KPROBES=/d' "$DEFCONFIG_PATH" 2>/dev/null || true
echo "CONFIG_KSU_WITH_KPROBES=n" >> "$DEFCONFIG_PATH"

echo "==> KSU patch script finished."
