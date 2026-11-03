# Vendored sources

Code copied verbatim so tests and the E2E runs exercise providers' real contracts without
cross-repository CI credentials. Do not edit these files. To refresh a copy, re-copy it from its
pinned source and update this page (and, for Rain, rebuild the fixture).

## Bridge

| Directory                                    | Source                                                                                                                 | Commit                                                                    | License               |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | --------------------- |
| `bridge/src`                                 | [withbridge/spender-contract-evm](https://github.com/withbridge/spender-contract-evm) `src/`                           | `9675cb08177494846d9c36a4c3faf007285cdc0e` (main, "Audit Feedback (#13)") | MIT (Bridge Ventures) |
| `bridge/pending/spenders/SpenderErc4626.sol` | [withbridge/spender-contract-evm#14](https://github.com/withbridge/spender-contract-evm/pull/14) (unmerged, unaudited) | `728646d399c171ec90c3c803a53bfcf13a8cd0a9`                                | MIT (Bridge Ventures) |

Local modifications: `bridge/pending/spenders/SpenderErc4626.sol`, import paths only, so the
unmerged file compiles against the pinned `src/`.

`../test/bridge/harness/fixtures/Permit2.json` is Uniswap Permit2's creation code, built from
`lib/permit2` at `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` with that repository's own `foundry.toml`
(solc 0.8.17, `via_ir`, 1,000,000 optimizer runs), because Permit2's exact pragma cannot compile here.

## Rain

| Directory | Source                                                                                                                                            | Contracts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | License                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| `rain/`   | Rain's verified sources on Polygon (chain 137), from [Sourcify](https://sourcify.dev), with their original paths, OpenZeppelin 4.8 files included | `RainCollateral` [`0x31EBf70312f488D0bdAc374b340f0D01dBf153B5`](https://polygonscan.com/address/0x31EBf70312f488D0bdAc374b340f0D01dBf153B5#code), `RainCollateralController` [`0x5d5Cef756412045617415FC78D510003238EAfFd`](https://polygonscan.com/address/0x5d5Cef756412045617415FC78D510003238EAfFd#code), `RainCollateralFactory` (with `RainCollateralBeacon`) [`0x389c6f04D39fF038cC99F94BcE338D2f5Eb64a67`](https://polygonscan.com/address/0x389c6f04D39fF038cC99F94BcE338D2f5Eb64a67#code) | Unlicense (Rain); MIT (OpenZeppelin) |

Sourcify reports an exact creation and runtime match for all three. They compile with solc 0.8.17,
optimizer off, EVM version london. [`../script/rain/build-fixture.sh`](../script/rain/build-fixture.sh)
builds them with those settings into `../test/rain/fixtures/rain.json`; with `--verify` it checks each
build against Polygon's deployed bytecode, which it matches apart from the CBOR metadata hashes
(they hash source paths). Rain may run newer versions on other chains, such as its real-time
funding contracts, which are not public. Local modifications: none.

## Zones runtime

| Directory                 | Source                                                                                                                                                                                                                                             | Commit                                     | License           |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ----------------- |
| `tempo-zones/src/runtime` | [tempoxyz/tempo](https://github.com/tempoxyz/tempo) `crates/zones/contracts/src/runtime/{interfaces,libraries}` and `tempo/{ZonePortal,ZoneMessenger,Verifier}.sol` (Zones moved into the Tempo monorepo; tempoxyz/zones is archived at `d62366c`) | `ce9998460dad466d0d36c05c971c988dc7e67582` | MIT or Apache-2.0 |

`lib/tempo-std` (installed by `scripts/solidity-deps.sh cards` from `foundry.lock`) is pinned to
`96f882963ce3b0e0abc7ec2b41d03d42457877bb`, the revision the vendored Zones contracts compile against.

Tempo Earn is not vendored: this project imports `earn/src/` through the `tempo-earn/` remapping. The
E2E runs (`e2e/cards/`) and `script/bridge/smoke.sh` read the L1 and Zone images and the TIP-1091
runtime bytecode from [`localnet/fixtures/`](../../localnet/fixtures/) (checked by SHA-256 at startup).
