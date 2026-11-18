# Reservation core differential test

`MockReservationCore` (`../harness/`) models the node's reservation core precompile for the programs' tests. This
folder proves the model matches the node.

- `traces/seed-<n>.json`: random operation sequences recorded on a Tempo dev node. Each operation stores its sender,
  block time, call, outcome (ok or revert data), the core events it emitted, and the changes to the full core state
  `StateReader` reads (balances, reserved, available, budgets, payee terms, debts and holds over a fixed set of
  accounts, tokens and hold ids).
- `Differential.t.sol` replays every trace against the model and requires the same outcome, revert data, events and
  state after every operation, then checks the core invariants (`CoreInvariants.sol`).
- `ModelRandom.t.sol` runs the same kind of sequences against the model alone, without a node, checking the
  invariants only.

Regenerate the traces from the harness repository (tempoxyz/cards), with a tempo binary built from the core branch:

```sh
forge build    # in this cards/ folder: the script reads the core ABI and StateReader from out/
TEMPO_BIN=<path to tempo> pnpm differential --cards <this checkout>/cards --node --seeds 1,2,3,4,5,6,7,8 --ops 200
```

`--node` starts a fresh dev node on port 18545 (`DIFF_RPC_PORT`) and stops it afterwards; without it the script uses
`DIFF_RPC_URL`. It moves time with the node's dev clock (`tempo_devSetTime`).
