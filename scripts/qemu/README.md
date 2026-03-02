# QEMU build artifacts

This folder contains the build script used in CI to produce pinned QEMU binaries for
qemu-builds releases.

## Build locally (macOS/Linux)

```bash
QEMU_VERSION=8.2.1 \
PLATFORM=darwin \
ARCH=arm64 \
OUTPUT_DIR=dist/qemu \
./scripts/qemu/build.sh
```

The script produces:
- `vibebox-qemu-<version>-<platform>-<arch>.tar.gz`
- `vibebox-qemu-<version>-<platform>-<arch>.tar.gz.sha256`

The archive contains:
- `qemu-system-*` for the target arch
- `qemu-img`

## Release flow

1. Set `scripts/qemu/version.txt` to the QEMU version you want to pin.
2. Run the `build-qemu` GitHub Actions workflow (or use the release trigger).
   - GitHub: Actions → Build QEMU → Run workflow (leave `qemu_version` blank to use `scripts/qemu/version.txt`).
3. Upload the generated archives + sha256 files to the qemu-builds release.
4. Update the pinned QEMU config in vibebox to match the new release.

Notes:
- CI uses the upstream QEMU tarball. If you need stronger provenance, add a source hash
  check and mirror the tarball.
- macOS builds run on `macos-15` (arm64) GitHub runners only.
- Linux builds currently target x64 only. Add a Linux arm64 runner to publish that artifact.
