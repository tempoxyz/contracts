#!/usr/bin/env bash
# Installs a Foundry project's Solidity dependencies into <project>/lib/ at the revisions its
# foundry.lock pins. Each project (earn/, zone-router/, cards/) pins its own; they are not Git submodules.
# A project that compiles with solar (earn/) pins its revision in <project>/solar.lock; cargo installs
# it into .solar/<rev>/ with a local digest receipt, where the project's solar-solc wrapper finds it.
# Runs on bash 3.2 (macOS's /bin/bash), so it uses no associative arrays.
# Usage: scripts/solidity-deps.sh <project>...   (idempotent; a checkout at its pin is kept)
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
    expected = {"schemaVersion": 1, "sourceRevision": revision,
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
  echo "solar $rev needs a fresh pinned rebuild: missing or mismatched install receipt" >&2
  mkdir -p "$PWD/.solar"
  lock="$PWD/.solar/.install-$rev.lock"
  mkdir "$lock" 2>/dev/null || {
    echo "solar install is locked at $lock; wait for the installer, or remove a stale lock before rerunning pnpm deps" >&2
    exit 1
  }
  temporary=
  trap 'if [[ -n "$temporary" ]]; then rm -rf "$temporary"; fi; rmdir "$lock"' EXIT
  # Another installer may have finished between the initial check and acquiring the lock.
  if solar_receipt verify "$destination" "$rev"; then exit 0; fi
  temporary=$(mktemp -d "$PWD/.solar/.build-$rev.XXXXXX")
  cargo install --quiet --locked --git https://github.com/paradigmxyz/solar --rev "$rev" \
    --root "$temporary" solar-compiler
  solar_receipt write "$temporary" "$rev" || {
    echo "cargo did not produce an executable solar compiler; no installation published" >&2
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

[[ $# -gt 0 ]] || { echo "usage: $0 <project>..." >&2; exit 2; }
for project in "$@"; do
  python3 -c 'import json, sys; [print(p, e.get("tag", e)["rev"]) for p, e in json.load(open(sys.argv[1])).items()]' \
    "$project/foundry.lock" |
    while read -r path rev; do
      name=$(basename "$path")
      url=$(source_url "$name") || { echo "no source URL for $name in $0" >&2; exit 1; }
      dir="$project/$path"
      if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" == "$rev" ]]; then continue; fi
      rm -rf "$dir"
      git init -q "$dir"
      git -C "$dir" fetch -q --depth 1 "$url" "$rev"
      git -C "$dir" checkout -q FETCH_HEAD
      echo "$dir at $rev"
    done
  if [[ -f "$project/solar.lock" ]]; then
    rev=$(tr -d '[:space:]' < "$project/solar.lock")
    install_solar "$rev"
  fi
done
