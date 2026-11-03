#!/usr/bin/env bash
# Builds the vendored Rain contracts (vendor/rain) with the settings Polygonscan verified them with
# (solc 0.8.17, optimizer off, london) and writes their creation code to test/rain/fixtures/rain.json,
# which tests and scripts deploy, because their exact pragma cannot compile with this project's
# settings. --verify also checks each build against the bytecode Rain deployed on Polygon, through
# Sourcify, ignoring only the CBOR metadata hashes (they hash source paths, which differ here).
# The sources sit outside this build's root, so solc names them by absolute path and the metadata
# hashes differ between checkouts. --check therefore leaves the fixture alone and fails unless a fresh
# build matches it apart from those hashes.
# Usage (from cards/): script/rain/build-fixture.sh [--verify] [--check]
set -euo pipefail
cd "$(dirname "$0")"
forge build --quiet
cd ../..
python3 - "$@" <<'PY'
import json, re, sys, urllib.request
contracts = {
    "RainCollateral": "0x31EBf70312f488D0bdAc374b340f0D01dBf153B5",
    "RainCollateralController": "0x5d5Cef756412045617415FC78D510003238EAfFd",
    "RainCollateralFactory": "0x389c6f04D39fF038cC99F94BcE338D2f5Eb64a67",
}
fixture = {"chainId": 137, "compiler": "0.8.17", "optimizer": False, "evmVersion": "london", "contracts": {}}
strip = lambda h: re.sub(r"a264697066735822[0-9a-f]{68}64736f6c63430008110033", "", h.lower().removeprefix("0x"))
for name, polygon in contracts.items():
    artifact = json.load(open(f"out/rain/{name}.sol/{name}.json"))
    fixture["contracts"][name] = {"polygon": polygon, "bytecode": artifact["bytecode"]["object"]}
    if "--verify" in sys.argv:
        url = f"https://sourcify.dev/server/v2/contract/137/{polygon}?fields=runtimeBytecode"
        onchain = json.load(urllib.request.urlopen(url))["runtimeBytecode"]["onchainBytecode"]
        same = strip(onchain) == strip(artifact["deployedBytecode"]["object"])
        print(f"{name}: {'matches' if same else 'DIFFERS FROM'} Polygon {polygon}")
        if not same:
            sys.exit(1)
if "--check" in sys.argv:
    committed = json.load(open("test/rain/fixtures/rain.json"))["contracts"]
    stale = [n for n, c in fixture["contracts"].items()
             if n not in committed or strip(committed[n]["bytecode"]) != strip(c["bytecode"])]
    if stale:
        print("test/rain/fixtures/rain.json is stale for: " + ", ".join(stale) + "; run script/rain/build-fixture.sh")
        sys.exit(1)
    print("test/rain/fixtures/rain.json matches vendor/rain apart from metadata hashes")
    sys.exit(0)
json.dump(fixture, open("test/rain/fixtures/rain.json", "w"), indent=2)
open("test/rain/fixtures/rain.json", "a").write("\n")
print("wrote test/rain/fixtures/rain.json")
PY
