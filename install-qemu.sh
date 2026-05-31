#!/usr/bin/env bash
set -euo pipefail

YES=0
if [[ "${1:-}" == "--yes" ]]; then
  YES=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--yes]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/scripts/qemu/version.txt" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  echo "scripts/qemu/version.txt missing or empty" >&2
  exit 1
fi

for cmd in curl tar awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64|x64) ARCH="x64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;;
esac
case "$PLATFORM" in
  darwin|linux) ;;
  *) echo "Unsupported platform: $PLATFORM" >&2; exit 1 ;;
esac

if [[ "$ARCH" == "arm64" ]]; then
  SYS_BIN="qemu-system-aarch64"
else
  SYS_BIN="qemu-system-x86_64"
fi
IMG_BIN="qemu-img"
INSTALL_DIR="$PWD/.qemu"
REPO="g/qemu-builds"

ASSET="qemu-${VERSION}-${PLATFORM}-${ARCH}.tar.gz"
SHA_ASSET="${ASSET}.sha256"
BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"
ARCHIVE_PATH="$(mktemp -t qemu-archive).tar.gz"
SHA_PATH="$(mktemp -t qemu-sha).txt"
ENT_PATH="$(mktemp -t qemu-entitlements).plist"
cleanup() {
  rm -f "$ARCHIVE_PATH" "$SHA_PATH" "$ENT_PATH"
}
trap cleanup EXIT

echo "[install-qemu] downloading: $ASSET"
curl -fsSL "${BASE_URL}/${ASSET}" -o "$ARCHIVE_PATH"
curl -fsSL "${BASE_URL}/${SHA_ASSET}" -o "$SHA_PATH"

EXPECTED_SHA="$(awk -v asset="$ASSET" '$0 ~ asset {print $1; exit}' "$SHA_PATH")"
[[ -n "$EXPECTED_SHA" ]] || EXPECTED_SHA="$(awk '{print $1; exit}' "$SHA_PATH")"
if [[ ! "$EXPECTED_SHA" =~ ^[a-fA-F0-9]{64}$ ]]; then
  echo "Invalid SHA256 in ${SHA_ASSET}" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
else
  ACTUAL_SHA="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
fi
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  echo "SHA256 mismatch for $ASSET" >&2
  exit 1
fi

if [[ "$PLATFORM" == "darwin" && "$YES" -ne 1 ]]; then
  [[ -t 0 ]] || { echo "macOS install requires prompt. Use --yes in non-interactive mode." >&2; exit 1; }
  echo "Warning: binaries are not Apple Developer ID signed"
  printf 'Proceed with local ad-hoc signing? [y/N] '
  read -r ANSWER
  [[ "$ANSWER" =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; }
fi

mkdir -p "$INSTALL_DIR"
find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
while IFS= read -r entry; do
  if [[ "$entry" == /* || "$entry" == *".."* ]]; then
    echo "Unsafe archive entry: $entry" >&2
    exit 1
  fi
done < <(tar -tzf "$ARCHIVE_PATH")
tar -xzf "$ARCHIVE_PATH" -C "$INSTALL_DIR" --no-same-owner --no-same-permissions

SYS_PATH="$INSTALL_DIR/$SYS_BIN"
IMG_PATH="$INSTALL_DIR/$IMG_BIN"
[[ -x "$SYS_PATH" ]] || { echo "Missing expected system binary: $SYS_PATH" >&2; exit 1; }
[[ -x "$IMG_PATH" ]] || { echo "Missing expected image binary: $IMG_PATH" >&2; exit 1; }

if [[ "$PLATFORM" == "darwin" ]]; then
  for cmd in xattr codesign find; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required macOS command: $cmd" >&2; exit 1; }
  done
  xattr -dr com.apple.provenance "$INSTALL_DIR" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$INSTALL_DIR" 2>/dev/null || true

  if [[ -d "$INSTALL_DIR/lib" ]]; then
    while IFS= read -r -d '' dylib; do
      chmod u+w "$dylib" 2>/dev/null || true
      codesign --force --sign - "$dylib"
    done < <(find "$INSTALL_DIR/lib" -type f -name '*.dylib' -print0)
  fi

  cat > "$ENT_PATH" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.hypervisor</key>
  <true/>
</dict>
</plist>
ENT

  chmod u+w "$IMG_PATH" 2>/dev/null || true
  codesign --force --sign - "$IMG_PATH"
  chmod u+w "$SYS_PATH" 2>/dev/null || true
  codesign --force --sign - --entitlements "$ENT_PATH" "$SYS_PATH"
  codesign --verify --strict --verbose=2 "$IMG_PATH"
  codesign --verify --strict --verbose=2 "$SYS_PATH"
fi

"$IMG_PATH" --version >/dev/null

echo "[install-qemu] installed: $INSTALL_DIR"
echo "[install-qemu] qemu path: $SYS_PATH"
