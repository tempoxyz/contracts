# Threat models

Each threat model describes one system: who can attack it, its trust boundaries, the invariants it must
keep and the risks its design accepts. Each opens with a **Covers** list of the paths it models, and it
follows Trail of Bits' TRAIL method.

| Model                       | System                                                          | Owner        |
| :-------------------------- | :-------------------------------------------------------------- | :----------- |
| [Card spend](card-spend.md) | Card programs, their providers and the Zone router's Spend path | Kartik Patel |

These paths need no threat model: tests (`**/test/**`), `e2e/`, `localnet/`, `docs/` and `profiles/`.
Update a model in the same pull request as a change to the paths it covers, as its "Keeping this model
current" section says.
