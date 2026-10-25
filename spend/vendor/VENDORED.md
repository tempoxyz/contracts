# Vendored sources

Code copied verbatim from other repositories so the harness can run the real contracts without
cross-repository CI credentials. Do not edit these files. To refresh a copy, re-copy from the pinned
commit and update the table.

| Directory | Source | Commit | License |
| --- | --- | --- | --- |
| `bridge-spender/src` | [withbridge/spender-contract-evm](https://github.com/withbridge/spender-contract-evm) `src/` | `9675cb08177494846d9c36a4c3faf007285cdc0e` (main, "Audit Feedback (#13)") | MIT (Bridge Ventures) |
| `bridge-spender/pending/spenders/SpenderErc4626.sol` | [withbridge/spender-contract-evm#14](https://github.com/withbridge/spender-contract-evm/pull/14) (unmerged, unaudited) | `728646d399c171ec90c3c803a53bfcf13a8cd0a9` | MIT (Bridge Ventures) |
| `tempo-zones/src/runtime` | [tempoxyz/tempo](https://github.com/tempoxyz/tempo) `crates/zones/contracts/src/runtime/{interfaces,libraries}` and `tempo/{ZonePortal,ZoneMessenger,Verifier}.sol` (Zones moved into the Tempo monorepo; tempoxyz/zones is archived at `d62366c`) | `ce9998460dad466d0d36c05c971c988dc7e67582` | MIT or Apache-2.0 |

Local modifications:

- `bridge-spender/pending/spenders/SpenderErc4626.sol`: import paths only, so the unmerged file
  compiles against the pinned `src/`.

`test/harness/fixtures/Permit2.json` is Uniswap Permit2's creation code, built from `lib/permit2`
at `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` with that repository's own `foundry.toml` (solc
0.8.17, `via_ir`, 1,000,000 optimizer runs), because Permit2's exact pragma cannot compile here.

`lib/tempo-std` (installed by `script/deps.sh` from `foundry.lock`) is pinned to `96f882963ce3b0e0abc7ec2b41d03d42457877bb`, the revision the vendored
zones contracts compile against.

Tempo Earn is not vendored: this project lives in Earn's repository and imports its `src/` through
the `tempo-earn/` remapping. `e2e/zone` and `script/smoke.sh` read the L1 and Zone images and the
TIP-1091 runtime bytecode from Earn's [`localnet/fixtures/`](../../localnet/fixtures/) (checked by
SHA-256 at startup); `e2e/zone/src/network.ts` is adapted from Earn's `localnet/src/network.ts`.
