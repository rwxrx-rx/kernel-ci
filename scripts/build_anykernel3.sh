#!/usr/bin/env bash
# scripts/build_anykernel3.sh <variant-suffix>
# Produces out/<KERNEL_NAME>-<CODENAME>-<variant>-<date>.zip
#
# Overlays two pinned files (update-binary, ak3-core.sh — from
# patches/camellia-anykernel/) onto a fresh AnyKernel3 clone, matching a
# proven working build for this device. Fresh-clone still supplies the
# standard AK3 tools/ binaries (busybox, magiskboot, lptools_static,
# ...) — only those two specific files are pinned, everything else
# comes from upstream AnyKernel3 as before.
#
# For ReSukiSU specifically, also stages the "resukisu-bootstrap"
# payload (ksud launcher + the official ksud/libadbroot.so native libs,
# extracted from OUR OWN manager-build job's output APK — not a
# third-party mirror) plus the public meta-overlayfs module release.
# This is entirely self-contained: if manager-build didn't produce a
# usable APK (see manager-build.yml's notes on ReSukiSU being hard to
# build), this step skips the bootstrap payload gracefully — the kernel
# zip still gets produced, just without that convenience payload.
set -euo pipefail

SUFFIX="${1:?usage: build_anykernel3.sh <variant-suffix>}"
: "${GITHUB_WORKSPACE:?}"
: "${KERNEL_NAME:?}"
: "${CODENAME:?}"
: "${ANYKERNEL_REPO:?}"
: "${ANYKERNEL_BRANCH:?}"
CODENAME_ALT="${CODENAME_ALT:-}"
KSU_VARIANT="${KSU_VARIANT:-none}"
MANAGER_APK_DIR="${MANAGER_APK_DIR:-}"

AK_DIR="$GITHUB_WORKSPACE/AnyKernel3"
rm -rf "$AK_DIR"
git clone --depth=1 -b "$ANYKERNEL_BRANCH" "$ANYKERNEL_REPO" "$AK_DIR"
rm -f "$AK_DIR"/anykernel.sh.orig

PINNED="$GITHUB_WORKSPACE/patches/camellia-anykernel"
if [ -f "$PINNED/update-binary" ] && [ -f "$PINNED/ak3-core.sh" ]; then
  echo "==> Overlaying pinned update-binary + ak3-core.sh"
  cp -f "$PINNED/update-binary" "$AK_DIR/META-INF/com/google/android/update-binary"
  cp -f "$PINNED/ak3-core.sh" "$AK_DIR/tools/ak3-core.sh"
  chmod 0755 "$AK_DIR/META-INF/com/google/android/update-binary" "$AK_DIR/tools/ak3-core.sh"
else
  echo "::warning::patches/camellia-anykernel/{update-binary,ak3-core.sh} not found — using whatever came with the fresh AnyKernel3 clone instead."
fi

# --- ReSukiSU bootstrap payload (best-effort, self-contained) ---------
RESUKISU_BOOTSTRAP_STAGED=false
if [ "$KSU_VARIANT" = "resukisu" ] && [ -n "$MANAGER_APK_DIR" ]; then
  OFFICIAL_APK="$(find "$MANAGER_APK_DIR" -maxdepth 1 -type f -name '*.apk' 2>/dev/null | head -n1)"
  TEMPLATES="$GITHUB_WORKSPACE/patches/resukisu-bootstrap-templates"
  if [ -n "$OFFICIAL_APK" ] && [ -f "$TEMPLATES/ksud" ] && [ -f "$TEMPLATES/bootstrap-meta.sh" ]; then
    echo "==> Staging ReSukiSU userspace bootstrap from $OFFICIAL_APK"
    BS="$AK_DIR/resukisu-bootstrap"
    mkdir -p "$BS"
    if unzip -p "$OFFICIAL_APK" lib/arm64-v8a/libksud.so > "$BS/ksud.susmap" 2>/dev/null \
       && unzip -p "$OFFICIAL_APK" lib/arm64-v8a/libadbroot.so > "$BS/libadbroot.so" 2>/dev/null \
       && [ -s "$BS/ksud.susmap" ] && [ -s "$BS/libadbroot.so" ]; then
      cp -f "$TEMPLATES/ksud" "$BS/ksud"
      cp -f "$TEMPLATES/bootstrap-meta.sh" "$BS/bootstrap-meta.sh"
      sha256sum "$BS/ksud.susmap" > "$BS/ksud.sha256"
      chmod 0755 "$BS/ksud" "$BS/ksud.susmap" "$BS/libadbroot.so" "$BS/bootstrap-meta.sh"

      META_URL="https://github.com/KernelSU-Modules-Repo/meta-overlayfs/releases/download/v1.3.1/meta-overlayfs-13100-1.3.1.zip"
      if curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 "$META_URL" -o "$BS/meta-overlayfs-13100-1.3.1.zip" \
         && unzip -t "$BS/meta-overlayfs-13100-1.3.1.zip" >/dev/null 2>&1; then
        RESUKISU_BOOTSTRAP_STAGED=true
        echo "    bootstrap payload staged (ksud + libadbroot.so + meta-overlayfs)."
      else
        echo "::warning::meta-overlayfs download failed — dropping bootstrap payload for this build."
        rm -rf "$BS"
      fi
    else
      echo "::warning::libksud.so / libadbroot.so not found inside $OFFICIAL_APK (APK may be a debug fallback build, not the real ReSukiSU manager) — skipping bootstrap payload."
      rm -rf "$BS"
    fi
  else
    echo "No manager APK available for ReSukiSU bootstrap staging — building without it (kernel zip is still produced normally)."
  fi
fi

DEVICE_NAMES="device.name1=${CODENAME}"
[ -n "$CODENAME_ALT" ] && DEVICE_NAMES="${DEVICE_NAMES}
device.name2=${CODENAME_ALT}"

BOOTSTRAP_CALL=""
if [ "$RESUKISU_BOOTSTRAP_STAGED" = "true" ]; then
  BOOTSTRAP_CALL='
install_resukisu_userspace() {
  local adb=/data/adb;
  local bootstrap="$adb/ksu-bootstrap";
  mkdir -p "$bootstrap" || abort "Cannot create /data/adb bootstrap directory";
  local staged="$bootstrap/.staged";
  rm -rf "$staged";
  mkdir -p "$staged" || abort "Cannot create userspace staging directory";
  unzip -p "$ZIPFILE" resukisu-bootstrap/ksud > "$staged/ksud" || abort "Cannot extract ksud launcher";
  unzip -p "$ZIPFILE" resukisu-bootstrap/ksud.susmap > "$staged/ksud.susmap" || abort "Cannot extract official ksud";
  unzip -p "$ZIPFILE" resukisu-bootstrap/ksud.sha256 > "$staged/ksud.sha256" || abort "Cannot extract ksud digest";
  unzip -p "$ZIPFILE" resukisu-bootstrap/libadbroot.so > "$staged/libadbroot.so" || abort "Cannot extract libadbroot";
  unzip -p "$ZIPFILE" resukisu-bootstrap/meta-overlayfs-13100-1.3.1.zip > "$staged/meta-overlayfs-13100-1.3.1.zip" || abort "Cannot extract meta-overlayfs";
  unzip -p "$ZIPFILE" resukisu-bootstrap/bootstrap-meta.sh > "$staged/bootstrap-meta.sh" || abort "Cannot extract metamodule bootstrap";
  chmod 0755 "$staged/ksud" "$staged/ksud.susmap" "$staged/libadbroot.so" "$staged/bootstrap-meta.sh";
  local expected actual;
  expected=$(awk "NR==1 {print \$1}" "$staged/ksud.sha256") || abort "Cannot read ksud digest";
  actual=$(sha256sum "$staged/ksud.susmap" | awk "{print \$1}") || abort "Cannot hash official ksud";
  [ "${#expected}" -eq 64 ] && [ "$actual" = "$expected" ] || abort "Official ksud digest mismatch";
  for item in ksud ksud.susmap ksud.sha256 libadbroot.so meta-overlayfs-13100-1.3.1.zip bootstrap-meta.sh; do
    mv -f "$staged/$item" "$bootstrap/$item" || abort "Cannot activate staged userspace: $item";
  done;
  rmdir "$staged" 2>/dev/null || true;
  ui_print " [OK] ReSukiSU and meta-overlayfs payloads staged; Android init will install them";
}
install_resukisu_userspace;
'
fi

cat > "$AK_DIR/anykernel.sh" <<EOF
# AnyKernel3 config — generated by scripts/build_anykernel3.sh
properties() { '
kernel.string=${KERNEL_NAME} for ${CODENAME}
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
${DEVICE_NAMES}
supported.versions=
supported.patchlevels=
'; }

boot_attributes() {
  set_perm_recursive 0 0 755 644 \$RAMDISK/*;
  set_perm_recursive 0 0 750 750 \$RAMDISK/init* \$RAMDISK/sbin;
}

block=boot;
is_slot_device=auto;
no_block_display=1;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

. tools/ak3-core.sh
${BOOTSTRAP_CALL}
split_boot;
flash_boot;
flash_dtbo;
EOF

mkdir -p "$AK_DIR"
cp "$GITHUB_WORKSPACE"/out/Image "$AK_DIR/" 2>/dev/null || true
cp "$GITHUB_WORKSPACE"/out/*.dtb "$AK_DIR/" 2>/dev/null || true
find "$GITHUB_WORKSPACE/out" -iname '*dtbo*.img' -exec cp {} "$AK_DIR/dtbo.img" \; 2>/dev/null || true

DATE_TAG="$(date +%Y%m%d-%H%M)"
ZIP_NAME="${KERNEL_NAME}-${CODENAME}-${SUFFIX}-${DATE_TAG}.zip"

( cd "$AK_DIR" && zip -r9 -q "$GITHUB_WORKSPACE/$ZIP_NAME" . -x '.git/*' )

echo "path=$GITHUB_WORKSPACE/$ZIP_NAME" >> "$GITHUB_OUTPUT"
echo "name=$ZIP_NAME" >> "$GITHUB_OUTPUT"
echo "Packaged: $ZIP_NAME"
if [ "$RESUKISU_BOOTSTRAP_STAGED" = "true" ]; then
  echo "  (includes ReSukiSU userspace bootstrap payload)"
fi
exit 0
