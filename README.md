# qemu-builds

This repo publishes prebuilt QEMU binaries used by vibebox.

Artifacts are produced by GitHub Actions and uploaded as release assets. The
vibebox SDK downloads them by version and verifies SHA256 hashes before use.

## Release process

1. Update `scripts/qemu/version.txt` to the desired QEMU version.
2. Run the `Build QEMU` workflow (or publish a release to trigger it).
3. Attach artifacts + `.sha256` files to the release.
4. Update vibebox pinned hashes to match the new release.

## Install script

Use `install-qemu.sh` to download a release artifact, verify SHA256 and install it to `.qemu`.

```bash
curl -fsSL https://raw.githubusercontent.com/g/qemu-builds/main/install-qemu.sh | bash
```

Non-interactive macOS mode:

```bash
curl -fsSL https://raw.githubusercontent.com/g/qemu-builds/main/install-qemu.sh | bash -s -- --yes
```

Only supported flag is `--yes`.
