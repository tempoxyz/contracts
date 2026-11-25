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

Each file under `bridge/` as vendored, by SHA-256.
[`deployments/vendored.test.ts`](../deployments/vendored.test.ts) fails when a file changes, appears or
disappears without this table. `src/spenders/SpenderBase.sol`, `src/ISpenderHandler.sol` and
`src/lib/IFactory.sol` compile into the deployed "TS" handler
([`SpenderTempoSpend`](../src/spend/providers/bridge/SpenderTempoSpend.sol)); the other files serve only
tests and E2E runs.

| File                                                      | SHA-256                                                            |
| --------------------------------------------------------- | ------------------------------------------------------------------ |
| `bridge/LICENSE`                                          | `42a8aab48c21b922a153eaa87cc1a800e8b38a545590c72c53d001ba1aff13b1` |
| `bridge/pending/spenders/SpenderErc4626.sol`              | `de351812114a59e4d533958a5dcd1866f73fc14bae797aafad92cf586e27cda8` |
| `bridge/src/ISpenderHandler.sol`                          | `62a694b95dd65a2ddc7df7fedeaae40909fbae9fca5bb5bae68bd17afc2faa81` |
| `bridge/src/SpenderDelegator.sol`                         | `f2a3153a987f0a6001f37599732ff2a266fd2569ee77a88cdfe43bff970c4d7b` |
| `bridge/src/SpenderFactory.sol`                           | `ac375fc56b51ba18c081840e2bf99543302c3a01d5e75989a755eb5d4cdb5575` |
| `bridge/src/SpenderFactoryErrorsAndEvents.sol`            | `883f09d265960c72706b20af89218075e8694d39953207bffb28f54ba3c567c3` |
| `bridge/src/lib/IFactory.sol`                             | `247a1fdb954064420c3362184c4b70ca3b42c17a72ff5462d4002869e27e4202` |
| `bridge/src/lib/SpenderFactoryStorage.sol`                | `cfb9f3aabf502ea28e3da9368157ff6505c7eb4c79bfd9d1dc5269b0022f7639` |
| `bridge/src/spenders/SpenderBase.sol`                     | `f8494f5b20f1808d297e5de6b102168e72e8bda3ddbab0c10c102df6de80ef4b` |
| `bridge/src/spenders/SpenderErc20.sol`                    | `a54b391be6e2e05fc61654cae9cbe62462000019f4efab112240dc04b3624d4b` |
| `bridge/src/spenders/SpenderErc20WithRelayedApproval.sol` | `a5ff10999f618bea5723f2fd69d565b849ce7089ef3cb961ddf7c27969bb123b` |
| `bridge/src/spenders/SpenderPermit2.sol`                  | `103098163518228bb9688c6d4c14e8da8dc7b27ebafa66b3ec42b2e742feb590` |
| `bridge/src/spenders/SpenderTempoEarnWithFallback.sol`    | `ebd815702bdf05c89d7167bc8c02237b489880687b96e20ccdd730c24d2fd39a` |

`test/spend/bridge/harness/fixtures/Permit2.json` is Uniswap Permit2's creation code, built from
`lib/permit2` at `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` with that repository's own `foundry.toml`
(solc 0.8.17, `via_ir`, 1,000,000 optimizer runs), because Permit2's exact pragma cannot compile here.

## Rain

| Directory | Source                                                                                                                                            | Contracts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | License                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| `rain/`   | Rain's verified sources on Polygon (chain 137), from [Sourcify](https://sourcify.dev), with their original paths, OpenZeppelin 4.8 files included | `RainCollateral` [`0x31EBf70312f488D0bdAc374b340f0D01dBf153B5`](https://polygonscan.com/address/0x31EBf70312f488D0bdAc374b340f0D01dBf153B5#code), `RainCollateralController` [`0x5d5Cef756412045617415FC78D510003238EAfFd`](https://polygonscan.com/address/0x5d5Cef756412045617415FC78D510003238EAfFd#code), `RainCollateralFactory` (with `RainCollateralBeacon`) [`0x389c6f04D39fF038cC99F94BcE338D2f5Eb64a67`](https://polygonscan.com/address/0x389c6f04D39fF038cC99F94BcE338D2f5Eb64a67#code) | Unlicense (Rain); MIT (OpenZeppelin) |

Sourcify reports an exact creation and runtime match for all three. They compile with solc 0.8.17,
optimizer off, EVM version london. [`script/spend/rain/build-fixture.sh`](../script/spend/rain/build-fixture.sh)
builds them with those settings into `test/spend/rain/fixtures/rain.json`; with `--verify` it checks each
build against Polygon's deployed bytecode, which it matches apart from the CBOR metadata hashes
(they hash source paths). Rain may run newer versions on other chains, such as its real-time
funding contracts, which are not public. Local modifications: none.

## Zones runtime

| Directory                 | Source                                                                                                                                                                                                                                             | Commit                                     | License           |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ----------------- |
| `tempo-zones/src/runtime` | [tempoxyz/tempo](https://github.com/tempoxyz/tempo) `crates/zones/contracts/src/runtime/{interfaces,libraries}` and `tempo/{ZonePortal,ZoneMessenger,Verifier}.sol` (Zones moved into the Tempo monorepo; tempoxyz/zones is archived at `d62366c`) | `ce9998460dad466d0d36c05c971c988dc7e67582` | MIT or Apache-2.0 |

`lib/tempo-std` (installed by `scripts/solidity-deps.sh` from `foundry.lock`) is pinned to
`96f882963ce3b0e0abc7ec2b41d03d42457877bb`, the revision the vendored Zones contracts compile against.

Tempo Earn is not vendored: card spend imports `src/earn/` by relative path. The
E2E runs (`e2e/spend/`) and `script/spend/bridge/smoke.sh` read the L1 and Zone images and the TIP-1091
runtime bytecode from [`localnet/fixtures/`](../localnet/fixtures/) (checked by SHA-256 at startup).
