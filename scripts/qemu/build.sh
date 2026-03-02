#!/usr/bin/env bash
set -euo pipefail

QEMU_VERSION="${QEMU_VERSION:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/dist/qemu}"
ARCH="${ARCH:-}"
PLATFORM="${PLATFORM:-}"
TARGET_LIST="${TARGET_LIST:-}"
JOBS="${JOBS:-}"

if [[ -z "$QEMU_VERSION" ]]; then
  echo "QEMU_VERSION is required" >&2
  exit 1
fi

if [[ -z "$ARCH" ]]; then
  ARCH="$(uname -m)"
fi

if [[ -z "$PLATFORM" ]]; then
  PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
fi

case "$ARCH" in
  arm64|aarch64)
    ARCH_LABEL="arm64"
    QEMU_TARGET="aarch64-softmmu"
    QEMU_BINARY="qemu-system-aarch64"
    QEMU_IMG_BINARY="qemu-img"
    ;;
  x86_64|amd64|x64)
    ARCH_LABEL="x64"
    QEMU_TARGET="x86_64-softmmu"
    QEMU_BINARY="qemu-system-x86_64"
    QEMU_IMG_BINARY="qemu-img"
    ;;
  *)
    echo "Unsupported arch: $ARCH" >&2
    exit 1
    ;;
esac

if [[ -z "$TARGET_LIST" ]]; then
  TARGET_LIST="$QEMU_TARGET"
fi

if [[ -z "$JOBS" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
  else
    JOBS="$(sysctl -n hw.ncpu)"
  fi
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SRC_TAR="qemu-${QEMU_VERSION}.tar.xz"
SRC_URL="https://download.qemu.org/${SRC_TAR}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

curl -fsSL "$SRC_URL" -o "$WORK_DIR/$SRC_TAR"

tar -xf "$WORK_DIR/$SRC_TAR" -C "$WORK_DIR"

pushd "$WORK_DIR/qemu-${QEMU_VERSION}" >/dev/null

./configure \
  --target-list="$TARGET_LIST" \
  --disable-docs \
  --disable-gtk \
  --disable-sdl \
  --disable-vnc \
  --disable-curses \
  --disable-opengl \
  --disable-virtfs \
  --disable-brlapi \
  --disable-libnfs \
  --disable-rbd \
  --disable-smartcard \
  --disable-usb-redir \
  --disable-lzo \
  --disable-snappy \
  --disable-bzip2

make -j"$JOBS"

BIN_PATH="$(pwd)/build/$QEMU_BINARY"
if [[ ! -f "$BIN_PATH" ]]; then
  BIN_PATH="$(pwd)/$QEMU_BINARY"
fi

if [[ ! -f "$BIN_PATH" ]]; then
  FOUND="$(find "$(pwd)" -maxdepth 2 -type f -name "${QEMU_BINARY}*" | head -n 1 || true)"
  if [[ -z "$FOUND" ]]; then
    echo "QEMU binary not found after build: $QEMU_BINARY" >&2
    exit 1
  fi
  BIN_PATH="$FOUND"
fi

IMG_PATH="$(pwd)/build/$QEMU_IMG_BINARY"
if [[ ! -f "$IMG_PATH" ]]; then
  IMG_PATH="$(pwd)/$QEMU_IMG_BINARY"
fi

if [[ ! -f "$IMG_PATH" ]]; then
  FOUND_IMG="$(find "$(pwd)" -maxdepth 2 -type f -name "${QEMU_IMG_BINARY}*" | head -n 1 || true)"
  if [[ -z "$FOUND_IMG" ]]; then
    echo "QEMU img binary not found after build: $QEMU_IMG_BINARY" >&2
    exit 1
  fi
  IMG_PATH="$FOUND_IMG"
fi

if [[ "$PLATFORM" == "linux" ]]; then
  if ! command -v patchelf >/dev/null 2>&1; then
    echo "patchelf is required to bundle Linux shared libraries" >&2
    exit 1
  fi
fi

OUT_NAME="vibebox-qemu-${QEMU_VERSION}-${PLATFORM}-${ARCH_LABEL}.tar.gz"
STAGING="$WORK_DIR/staging"
LIB_DIR="$STAGING/lib"
mkdir -p "$LIB_DIR"
cp "$BIN_PATH" "$STAGING/$QEMU_BINARY"
cp "$IMG_PATH" "$STAGING/$QEMU_IMG_BINARY"

chmod +x "$STAGING/$QEMU_BINARY"
chmod +x "$STAGING/$QEMU_IMG_BINARY"

if [[ "$PLATFORM" == "darwin" ]]; then
  copy_macos_deps() {
    local bin="$1"
    otool -L "$bin" | tail -n +2 | awk '{print $1}' | while read -r dep; do
      case "$dep" in
        @*)
          continue
          ;;
        /System/Library/*|/usr/lib/*)
          continue
          ;;
      esac
      local base
      base="$(basename "$dep")"
      if [[ ! -f "$LIB_DIR/$base" ]]; then
        cp "$dep" "$LIB_DIR/$base"
        chmod +x "$LIB_DIR/$base"
      fi
      install_name_tool -change "$dep" "@rpath/$base" "$bin"
    done
  }

  copy_macos_deps "$STAGING/$QEMU_BINARY"
  copy_macos_deps "$STAGING/$QEMU_IMG_BINARY"

  install_name_tool -add_rpath "@loader_path/lib" "$STAGING/$QEMU_BINARY"
  install_name_tool -add_rpath "@loader_path/lib" "$STAGING/$QEMU_IMG_BINARY"

  if [[ -d "$LIB_DIR" ]]; then
    for lib in "$LIB_DIR"/*.dylib; do
      if [[ ! -f "$lib" ]]; then
        continue
      fi
      base="$(basename "$lib")"
      install_name_tool -id "@rpath/$base" "$lib"
      otool -L "$lib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
          @*)
            continue
            ;;
          /System/Library/*|/usr/lib/*)
            continue
            ;;
        esac
        dep_base="$(basename "$dep")"
        if [[ -f "$LIB_DIR/$dep_base" ]]; then
          install_name_tool -change "$dep" "@rpath/$dep_base" "$lib"
        fi
      done
    done
  fi
fi

if [[ "$PLATFORM" == "linux" ]]; then
  copy_linux_deps() {
    local bin="$1"
    ldd "$bin" | while read -r line; do
      dep="$(echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^\//) {print $i; break}}')"
      if [[ -z "$dep" ]]; then
        continue
      fi
      case "$dep" in
        /lib64/ld-linux*|/lib/ld-linux*|/lib/*/ld-linux*)
          continue
          ;;
      esac
      base="$(basename "$dep")"
      if [[ ! -f "$LIB_DIR/$base" ]]; then
        cp "$dep" "$LIB_DIR/$base"
        chmod +x "$LIB_DIR/$base"
      fi
    done
  }

  copy_linux_deps "$STAGING/$QEMU_BINARY"
  copy_linux_deps "$STAGING/$QEMU_IMG_BINARY"

  patchelf --set-rpath '$ORIGIN/lib' "$STAGING/$QEMU_BINARY"
  patchelf --set-rpath '$ORIGIN/lib' "$STAGING/$QEMU_IMG_BINARY"
fi

tar -czf "$OUTPUT_DIR/$OUT_NAME" -C "$STAGING" "$QEMU_BINARY" "$QEMU_IMG_BINARY" lib

if command -v shasum >/dev/null 2>&1; then
  (cd "$OUTPUT_DIR" && shasum -a 256 "$OUT_NAME" > "$OUT_NAME.sha256")
else
  (cd "$OUTPUT_DIR" && sha256sum "$OUT_NAME" > "$OUT_NAME.sha256")
fi

popd >/dev/null

echo "Built: $OUTPUT_DIR/$OUT_NAME"
