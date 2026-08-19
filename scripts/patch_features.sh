#!/usr/bin/env bash
set -euo pipefail

: "${KERNEL_DIR:?}"
: "${ARCH:?}"
: "${DEFCONFIG:?}"
: "${GITHUB_WORKSPACE:?}"

source "$GITHUB_WORKSPACE/manifest/features.env"

DEFCONFIG_PATH="$KERNEL_DIR/arch/${ARCH}/configs/${DEFCONFIG}"

append_defconfig() {
  # Safely handle empty parameters
  [ -z "${1:-}" ] && return 0
  
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    grep -q "^${key}=" "$DEFCONFIG_PATH" 2>/dev/null && sed -i "/^${key}=/d" "$DEFCONFIG_PATH"
    echo "$line" >> "$DEFCONFIG_PATH"
  done <<< "$1"
}

# 1. Fix KSU boottime (timespec mismatch on kernel 4.14)
#
# BUG FIXED: KernelSU forks integrate into a non-GKI tree via a SYMLINK
# (e.g. drivers/kernelsu -> ../KernelSU-Next/kernel — confirmed by
# setup.sh's own "[+] Symlink created." log line). GNU find does NOT
# descend into a directory reached through a symlink unless you pass
# -L. Without it, this whole loop silently matched zero files — sed
# never touched the real event.c, the build kept the original
# `struct timespec64` + `ktime_get_boottime_ts64`, and the mismatch
# only surfaced later at compile time with no hint that this patch step
# had done nothing. `-L` makes find follow the symlink so it actually
# reaches drivers/kernelsu/sulog/event.c.
for EVENT_C in $(find -L "$KERNEL_DIR" -type f -path "*/kernelsu*/event.c" 2>/dev/null); do
  echo "==> Fixing boottime struct in $EVENT_C"
  
  # Target the data type only so that it doesn't miss due to spaces/formatting
  sed -i 's/struct timespec64/struct timespec/g' "$EVENT_C"
  # Replace the function
  sed -i 's/ktime_get_boottime_ts64/get_monotonic_boottime/g' "$EVENT_C"
done

# 2. Check TCP BBR/Westwood
if [ "${FEATURE_TCP_BBR:-false}" = "true" ] && [ "${FEATURE_TCP_WESTWOOD:-false}" = "true" ]; then
  echo "::error::TCP BBR and Westwood can't both be the default congestion control."
  exit 1
fi

# 3. WireGuard
if [ "${FEATURE_WIREGUARD:-false}" = "true" ]; then
  echo "==> Enabling WireGuard"
  
  rm -rf "$KERNEL_DIR/drivers/net/wireguard" "$KERNEL_DIR/net/wireguard"
  sed -i '/wireguard/d' "$KERNEL_DIR/drivers/net/Kconfig" 2>/dev/null || true
  sed -i '/wireguard/d' "$KERNEL_DIR/drivers/net/Makefile" 2>/dev/null || true
  sed -i '/wireguard/d' "$KERNEL_DIR/net/Kconfig" 2>/dev/null || true
  sed -i '/wireguard/d' "$KERNEL_DIR/net/Makefile" 2>/dev/null || true

  WG_REPO="${WIREGUARD_REPO:-https://github.com/WireGuard/wireguard-linux-compat.git}"
  WG_BRANCH="${WIREGUARD_BRANCH:-master}"
  
  git clone --depth=1 -b "$WG_BRANCH" "$WG_REPO" "$GITHUB_WORKSPACE/wireguard-src"
  mkdir -p "$KERNEL_DIR/net/wireguard"
  cp -r "$GITHUB_WORKSPACE/wireguard-src/src/"* "$KERNEL_DIR/net/wireguard/"
  grep -q 'net/wireguard/Makefile' "$KERNEL_DIR/net/Makefile" 2>/dev/null \
    || echo 'obj-$(CONFIG_WIREGUARD) += wireguard/' >> "$KERNEL_DIR/net/Makefile"
  grep -q '"net/wireguard/Kconfig"' "$KERNEL_DIR/net/Kconfig" 2>/dev/null \
    || sed -i '/endmenu/i source "net/wireguard/Kconfig"' "$KERNEL_DIR/net/Kconfig"
  
  WG_COMPAT="$KERNEL_DIR/net/wireguard/compat/compat.h"
  if [ -f "$WG_COMPAT" ]; then
      python3 -c '
path = "'"$WG_COMPAT"'"
with open(path, "r") as f: text = f.read()

target = "struct __kernel_timespec {"
if target in text and "#ifndef __kernel_timespec" not in text:
    idx = text.find(target)
    brace = 0; end_idx = idx; started = False
    for i in range(idx, len(text)):
        if text[i] == "{": brace += 1; started = True
        elif text[i] == "}": brace -= 1
        if started and brace == 0: end_idx = i + 1; break
    block = text[idx:end_idx]
    text = text.replace(block, f"#ifndef __kernel_timespec\n{block}\n#endif")

text = text.replace("static __always_inline void old_synchronize_rcu(void)", "static __always_inline void wg_old_synchronize_rcu(void)")
text = text.replace("old_synchronize_rcu()", "wg_old_synchronize_rcu()")

with open(path, "w") as f: f.write(text)
'
      sed -i 's/struct timespec {/struct timespec_wg_unused {/g' "$WG_COMPAT"
      sed -i 's/struct timespec64 {/struct timespec64_wg_unused {/g' "$WG_COMPAT"
  fi

  append_defconfig "${WIREGUARD_DEFCONFIG:-CONFIG_WIREGUARD=y}"
fi

# 4. Baseband Guard
if [ "${FEATURE_BASEBAND_GUARD:-false}" = "true" ]; then
  echo "==> Integrating Baseband-guard (BBG)"
  if [ -n "${BBG_SETUP_URL:-}" ]; then
    ( cd "$KERNEL_DIR" && curl -LSs "$BBG_SETUP_URL" | bash - ) \
      || echo "::warning::Baseband-guard setup.sh reported an error"
  fi
  
  BBG_TRACING="$KERNEL_DIR/security/baseband-guard/tracing/tracing.c"
  if [ -f "$BBG_TRACING" ]; then
      sed -i 's/selinux_cred(/bbg_selinux_cred(/g' "$BBG_TRACING"
  fi

  append_defconfig "${BBG_DEFCONFIG:-}"
fi

# 5. ThinLTO
if [ "${FEATURE_THINLTO_O3:-false}" = "true" ]; then
  echo "==> Enabling ThinLTO + -O3"
  append_defconfig "${THINLTO_DEFCONFIG:-}"
  MAKEFILE="$KERNEL_DIR/Makefile"
  grep -q -- '-O2' "$MAKEFILE" && sed -i 's/-O2/-O3/g' "$MAKEFILE" || true
fi

# 6. ZRAM ZSTD
if [ "${FEATURE_ZRAM_ZSTD:-false}" = "true" ]; then
  echo "==> Enabling ZRAM + zstd"
  append_defconfig "${ZRAM_ZSTD_DEFCONFIG:-}"
fi

# 7. TCP BBR
if [ "${FEATURE_TCP_BBR:-false}" = "true" ]; then
  echo "==> Enabling TCP BBR"
  append_defconfig "${TCP_BBR_DEFCONFIG:-}"
fi

# 8. TCP Westwood
if [ "${FEATURE_TCP_WESTWOOD:-false}" = "true" ]; then
  echo "==> Enabling TCP Westwood"
  append_defconfig "${TCP_WESTWOOD_DEFCONFIG:-}"
fi

# 9. TTL Spoof
if [ "${FEATURE_TTL_SPOOF:-false}" = "true" ]; then
  echo "==> Staging TTL/Hop-Limit spoof"
  mkdir -p "$GITHUB_WORKSPACE/out/extra"
  cat > "$GITHUB_WORKSPACE/out/extra/00_ttl_spoof.sh" <<EOF
#!/system/bin/sh
sysctl -w net.ipv4.ip_default_ttl=${TTL_SPOOF_DEFAULT_VALUE:-64}
for f in /proc/sys/net/ipv6/conf/*/hop_limit; do
  echo ${TTL_SPOOF_DEFAULT_VALUE:-64} > "\$f" 2>/dev/null || true
done
EOF
  chmod +x "$GITHUB_WORKSPACE/out/extra/00_ttl_spoof.sh"
fi

# 10. DroidSpace
if [ "${FEATURE_DROIDSPACE:-false}" = "true" ]; then
  echo "==> Enabling DroidSpace prerequisites"
  append_defconfig "${DROIDSPACE_DEFCONFIG:-}"
fi

# 11. F2FS Opt
if [ "${FEATURE_F2FS_OPT:-false}" = "true" ]; then
  echo "==> Enabling F2FS optimizations"
  F2FS_H="$KERNEL_DIR/fs/f2fs/f2fs.h"
  if [ -f "$F2FS_H" ] && ! grep -q "FI_COMPRESS_RELEASED" "$F2FS_H"; then
      sed -i '/FI_NO_EXTENT/a \	FI_COMPRESS_RELEASED,' "$F2FS_H"
  fi
  append_defconfig "${F2FS_OPT_DEFCONFIG:-}"
fi

echo "Feature injection step finished."
