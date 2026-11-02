# Vendored sources

Code copied verbatim so tests and the E2E run providers' real contracts. Do not edit these files. To
refresh a copy, re-copy it from its source and rebuild the fixture.

| Directory | Source                                                                                                                                            | Contracts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | License                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| `rain/`   | Rain's verified sources on Polygon (chain 137), from [Sourcify](https://sourcify.dev), with their original paths, OpenZeppelin 4.8 files included | `RainCollateral` [`0x31EBf70312f488D0bdAc374b340f0D01dBf153B5`](https://polygonscan.com/address/0x31EBf70312f488D0bdAc374b340f0D01dBf153B5#code), `RainCollateralController` [`0x5d5Cef756412045617415FC78D510003238EAfFd`](https://polygonscan.com/address/0x5d5Cef756412045617415FC78D510003238EAfFd#code), `RainCollateralFactory` (with `RainCollateralBeacon`) [`0x389c6f04D39fF038cC99F94BcE338D2f5Eb64a67`](https://polygonscan.com/address/0x389c6f04D39fF038cC99F94BcE338D2f5Eb64a67#code) | Unlicense (Rain); MIT (OpenZeppelin) |

Sourcify reports an exact creation and runtime match for all three. They compile with solc 0.8.17,
optimizer off, EVM version london. [`../script/rain/build-fixture.sh`](../script/rain/build-fixture.sh)
builds them with those settings into `../test/fixtures/rain.json`; with `--verify` it checks each
build against Polygon's deployed bytecode, which it matches apart from the CBOR metadata hashes
(they hash source paths). Rain may run newer versions on other chains, such as its real-time
funding contracts, which are not public.

Local modifications: none.
