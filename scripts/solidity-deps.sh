#!/usr/bin/env bash
# Installs a Foundry project's Solidity dependencies into <project>/lib/ at the revisions its
# foundry.lock pins. Each project (earn/, spend/) pins its own; they are not Git submodules.
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
done
