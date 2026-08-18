#!/usr/bin/env bash
# scripts/patch_features.sh
# Reads the FEATURE_* booleans from env (set by clone-patch/action.yml
# from the workflow_dispatch toggles) and applies each enabled one.
set -euo pipefail

: "${KERNEL_DIR:?}"
: "${ARCH:?}"
: "${DEFCONFIG:?}"
: "${GITHUB_WORKSPACE:?}"

# features.env has multi-line CONFIG_ blocks per feature, which can't be
# passed through $GITHUB_ENV (KEY=value only) — source it directly.
source "$GITHUB_WORKSPACE/manifest/features.env"

DEFCONFIG_PATH="$KERNEL_DIR/arch/${ARCH}/configs/${DEFCONFIG}"

append_defconfig() {
  # $1 = newline-separated CONFIG_ lines
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    grep -q "^${key}=" "$DEFCONFIG_PATH" 2>/dev/null && sed -i "/^${key}=/d" "$DEFCONFIG_PATH"
    echo "$line" >> "$DEFCONFIG_PATH"
  done <<< "$1"
}

if [ "${FEATURE_TCP_BBR:-false}" = "true" ] && [ "${FEATURE_TCP_WESTWOOD:-false}" = "true" ]; then
  echo "::error::TCP BBR and Westwood can't both be the default congestion control — enable only one."
  exit 1
fi

if [ "${FEATURE_WIREGUARD:-false}" = "true" ]; then
  echo "==> Enabling WireGuard"
  git clone --depth=1 -b "$WIREGUARD_BRANCH" "$WIREGUARD_REPO" "$GITHUB_WORKSPACE/wireguard-src"
  mkdir -p "$KERNEL_DIR/net/wireguard"
  cp -r "$GITHUB_WORKSPACE/wireguard-src/src/"* "$KERNEL_DIR/net/wireguard/"
  grep -q 'net/wireguard/Makefile' "$KERNEL_DIR/net/Makefile" 2>/dev/null \
    || echo 'obj-$(CONFIG_WIREGUARD) += wireguard/' >> "$KERNEL_DIR/net/Makefile"
  grep -q '"net/wireguard/Kconfig"' "$KERNEL_DIR/net/Kconfig" 2>/dev/null \
    || sed -i '/endmenu/i source "net/wireguard/Kconfig"' "$KERNEL_DIR/net/Kconfig"
  append_defconfig "$WIREGUARD_DEFCONFIG"
fi

if [ "${FEATURE_BASEBAND_GUARD:-false}" = "true" ]; then
  echo "==> Integrating Baseband-guard (BBG)"
  ( cd "$KERNEL_DIR" && curl -LSs "$BBG_SETUP_URL" | bash - ) \
    || echo "::warning::Baseband-guard setup.sh reported an error — check its README for manual integration steps on this tree"
  append_defconfig "$BBG_DEFCONFIG"
fi

if [ "${FEATURE_THINLTO_O3:-false}" = "true" ]; then
  echo "==> Enabling ThinLTO + -O3"
  append_defconfig "$THINLTO_DEFCONFIG"
  # Belt-and-suspenders for trees whose Makefile doesn't gate -O3 behind
  # a Kconfig symbol: also swap the raw flag if present.
  MAKEFILE="$KERNEL_DIR/Makefile"
  grep -q -- '-O2' "$MAKEFILE" && sed -i 's/-O2/-O3/g' "$MAKEFILE" || true
fi

if [ "${FEATURE_ZRAM_ZSTD:-false}" = "true" ]; then
  echo "==> Enabling ZRAM + zstd"
  append_defconfig "$ZRAM_ZSTD_DEFCONFIG"
fi

if [ "${FEATURE_TCP_BBR:-false}" = "true" ]; then
  echo "==> Enabling TCP BBR"
  append_defconfig "$TCP_BBR_DEFCONFIG"
fi

if [ "${FEATURE_TCP_WESTWOOD:-false}" = "true" ]; then
  echo "==> Enabling TCP Westwood"
  append_defconfig "$TCP_WESTWOOD_DEFCONFIG"
fi

if [ "${FEATURE_TTL_SPOOF:-false}" = "true" ]; then
  echo "==> Staging TTL/Hop-Limit spoof (sysctl, applied at boot — see manifest/features.env note on why this isn't a kernel patch)"
  mkdir -p "$GITHUB_WORKSPACE/out/extra"
  cat > "$GITHUB_WORKSPACE/out/extra/00_ttl_spoof.sh" <<EOF
#!/system/bin/sh
# Installed by AnyKernel3 (extra asset) — run this from a boot-scripts
# module (e.g. via Magisk/KSU post-fs-data.d) to spoof TTL/hop-limit.
sysctl -w net.ipv4.ip_default_ttl=${TTL_SPOOF_DEFAULT_VALUE}
for f in /proc/sys/net/ipv6/conf/*/hop_limit; do
  echo ${TTL_SPOOF_DEFAULT_VALUE} > "\$f" 2>/dev/null || true
done
EOF
  chmod +x "$GITHUB_WORKSPACE/out/extra/00_ttl_spoof.sh"
fi

if [ "${FEATURE_DROIDSPACE:-false}" = "true" ]; then
  echo "==> Enabling DroidSpace (namespace/cgroup) kernel prerequisites"
  append_defconfig "$DROIDSPACE_DEFCONFIG"
  echo "Note: DroidSpace itself (droidspaces.org) is installed on-device as an app, not compiled into the kernel — this step only turns on the kernel configs it needs."
fi

echo "Feature injection step finished."
