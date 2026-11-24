#!/usr/bin/env bash
# Installs the Foundry project's Solidity dependencies into lib/ at the revisions foundry.lock pins;
# they are not Git submodules. The project compiles with the solar release solar.lock pins by its tag's
# commit; the release's own binary is installed into .solar/<rev>/ with a local digest receipt, where
# solar-solc (the compiler) finds it.
# Runs on bash 3.2 (macOS's /bin/bash), so it uses no associative arrays.
# Usage: scripts/solidity-deps.sh   (idempotent; a checkout at its pin is kept)
set -euo pipefail
cd "$(dirname "$0")/.."

source_url() {
  case "$1" in
    forge-std) echo https://github.com/foundry-rs/forge-std ;;
    openzeppelin-contracts) echo https://github.com/OpenZeppelin/openzeppelin-contracts ;;
    openzeppelin-contracts-upgradeable) echo https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable ;;
    permit2) echo https://github.com/Uniswap/permit2 ;;
    solady) echo https://github.com/Vectorized/solady ;;
    tempo-std) echo https://github.com/tempoxyz/tempo-std ;;
    *) return 1 ;;
  esac
}

# This local receipt detects replaced bytes; it is not a signature or an independent build attestation.
solar_receipt() {
  python3 - "$@" <<'RECEIPT'
import hashlib, json, os, pathlib, sys
mode, directory, revision = sys.argv[1:]
root = pathlib.Path(directory)
try:
    binary = root / "bin/solar"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("compiler is not executable")
    # Schema 3 marks installs of solar's published release binary, retiring earlier source builds.
    expected = {"schemaVersion": 3, "sourceRevision": revision,
                "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    path = root / "install-receipt.json"
    if mode == "write":
        path.write_text(json.dumps(expected, indent=2) + "\n")
    else:
        actual = json.loads(path.read_text())
        if actual != expected or type(actual["schemaVersion"]) is not int:
            raise ValueError("compiler does not match installation receipt")
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
RECEIPT
}

install_solar() (
  rev=$1
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid solar.lock revision" >&2; exit 1; }
  destination="$PWD/.solar/$rev"
  if solar_receipt verify "$destination" "$rev"; then exit 0; fi
  echo "solar $rev needs a fresh install: missing or mismatched install receipt" >&2
  mkdir -p "$PWD/.solar"
  lock="$PWD/.solar/.install-$rev.lock"
  mkdir "$lock" 2>/dev/null || {
    echo "solar install is locked at $lock; wait for the installer, or remove a stale lock before rerunning pnpm deps" >&2
    exit 1
  }
  temporary=
  source=
  trap 'if [[ -n "$temporary" ]]; then rm -rf "$temporary"; fi; if [[ -n "$source" ]]; then rm -rf "$source"; fi; rmdir "$lock"' EXIT
  # Another installer may have finished between the initial check and acquiring the lock.
  if solar_receipt verify "$destination" "$rev"; then exit 0; fi
  # Install solar's published release binary for this platform: solar-releases.json maps each pinned
  # release commit to its version and the SHA-256 of every platform's release archive.
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) target=x86_64-unknown-linux-musl ;;
    Linux-aarch64 | Linux-arm64) target=aarch64-unknown-linux-gnu ;;
    Darwin-arm64) target=aarch64-apple-darwin ;;
    Darwin-x86_64) target=x86_64-apple-darwin ;;
    *) echo "no solar release binary for $(uname -s) $(uname -m)" >&2; exit 1 ;;
  esac
  read -r version sha256 < <(python3 - solar-releases.json "$rev" "$target" <<'RELEASE'
import json, sys
path, revision, target = sys.argv[1:]
release = json.load(open(path)).get(revision)
if not release or target not in release["sha256"]:
    sys.exit(f"solar-releases.json lists no {target} release archive for {revision}")
print(release["version"], release["sha256"][target])
RELEASE
  ) || exit 1
  temporary=$(mktemp -d "$PWD/.solar/.build-$rev.XXXXXX")
  source=$(mktemp -d "$PWD/.solar/.source-$rev.XXXXXX")
  archive="$source/solar-$target.tar.gz"
  curl --fail --silent --show-error --location --output "$archive"     "https://github.com/paradigmxyz/solar/releases/download/v$version/solar-$target.tar.gz"
  # The archive is checked before anything in it is extracted, let alone run.
  python3 - "$archive" "$sha256" <<'CHECKSUM' || { echo "solar v$version $target archive does not match solar-releases.json" >&2; exit 1; }
import hashlib, sys
path, expected = sys.argv[1:]
sys.exit(hashlib.sha256(open(path, "rb").read()).hexdigest() != expected)
CHECKSUM
  tar -xzf "$archive" -C "$source" "solar-$target/solar"
  mkdir -p "$temporary/bin"
  mv "$source/solar-$target/solar" "$temporary/bin/solar"
  chmod 755 "$temporary/bin/solar"
  solar_receipt write "$temporary" "$rev" || {
    echo "the solar release archive held no executable compiler; no installation published" >&2
    exit 1
  }
  # Stage both files together; failed builds never touch the installed directory. Roll back a failed promotion.
  python3 - "$temporary" "$destination" <<'PROMOTE'
import os, pathlib, shutil, sys
staged, destination = map(pathlib.Path, sys.argv[1:])
backup = staged.with_name(staged.name + ".previous")
had_previous = os.path.lexists(destination)
if had_previous:
    os.replace(destination, backup)
try:
    os.replace(staged, destination)
except BaseException:
    if had_previous:
        os.replace(backup, destination)
    raise
if had_previous:
    if backup.is_symlink() or not backup.is_dir():
        backup.unlink()
    else:
        shutil.rmtree(backup)
PROMOTE
  echo "solar at $rev (install receipt recorded)"
)

[[ $# -eq 0 ]] || { echo "usage: $0" >&2; exit 2; }
python3 -c 'import json, sys; [print(p, e.get("tag", e)["rev"]) for p, e in json.load(open(sys.argv[1])).items()]'   foundry.lock |
  while read -r path rev; do
    name=$(basename "$path")
    url=$(source_url "$name") || { echo "no source URL for $name in $0" >&2; exit 1; }
    dir="$path"
    if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" == "$rev" ]]; then continue; fi
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$url" "$rev"
    git -C "$dir" checkout -q FETCH_HEAD
    echo "$dir at $rev"
  done
install_solar "$(tr -d '[:space:]' < solar.lock)"
