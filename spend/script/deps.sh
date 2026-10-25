#!/usr/bin/env bash
# Installs this project's Solidity dependencies into lib/ at the revisions foundry.lock pins.
# They are not submodules: spend/ shares Earn's repository, whose submodules are Earn's own.
# Usage: script/deps.sh   (idempotent; a checkout already at its pinned revision is kept)
set -euo pipefail
cd "$(dirname "$0")/.."

declare -A url=(
  [lib/forge-std]=https://github.com/foundry-rs/forge-std
  [lib/openzeppelin-contracts]=https://github.com/OpenZeppelin/openzeppelin-contracts
  [lib/openzeppelin-contracts-upgradeable]=https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable
  [lib/permit2]=https://github.com/Uniswap/permit2
  [lib/solady]=https://github.com/Vectorized/solady
  [lib/tempo-std]=https://github.com/tempoxyz/tempo-std
)

python3 -c 'import json; [print(p, e.get("tag", e).get("rev")) for p, e in json.load(open("foundry.lock")).items()]' |
  while read -r path rev; do
    [[ -n "${url[$path]:-}" ]] || { echo "no source URL for $path in script/deps.sh" >&2; exit 1; }
    if [[ "$(git -C "$path" rev-parse HEAD 2>/dev/null || true)" == "$rev" ]]; then continue; fi
    rm -rf "$path"
    git init -q "$path"
    git -C "$path" fetch -q --depth 1 "${url[$path]}" "$rev"
    git -C "$path" checkout -q FETCH_HEAD
    echo "$path at $rev"
  done
