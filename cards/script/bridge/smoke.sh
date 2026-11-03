#!/usr/bin/env bash
# Runs the card stack against a real Tempo dev node: deploys and broadcasts public pulls with forge
# and checks their balances with cast, then exercises Bridge's access key with cast (keychain
# authorize, atomic batch spend through the program's CardSpender, and the calls a leaked key must not
# be able to make), releases a program with release.sh, and deploys the private path's Spend-mode
# Zone router listing it.
#
# Usage: script/bridge/smoke.sh            starts and stops a node in Docker
#        RPC=http://... script/bridge/smoke.sh   uses an existing dev node
set -euo pipefail
cd "$(dirname "$0")/../.."

MNEMONIC="test test test test test test test test test test test junk"
mkdir -p reports
if [[ -z "${RPC:-}" ]]; then
  RPC=http://127.0.0.1:18545
  # The L1 image Earn's localnet and the Zone E2E pin.
  IMAGE=$(python3 -c "import json; print(json.load(open('../localnet/fixtures/runtime-lock.json'))['l1Image'])")
  docker rm -f bridge-tempo-node >/dev/null 2>&1 || true
  docker run -d --name bridge-tempo-node --platform linux/amd64 -p 18545:8545 "$IMAGE" \
    node --dev --dev.block-time 500ms --datadir /tmp/d --http --http.addr 0.0.0.0 --http.api all >/dev/null
  trap 'docker rm -f bridge-tempo-node >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 2; done
fi

forge script script/bridge/LocalSmoke.s.sol --rpc-url "$RPC" --broadcast --slow --gas-estimate-multiplier 105 \
  >reports/smoke-forge.log 2>&1 || { tail -40 reports/smoke-forge.log; exit 1; }
rm -rf foundry-pp

json() { python3 -c "import json,sys; print(json.load(open('reports/smoke.json'))['$1'])"; }
USD=$(json usd); CLONE=$(json clone); SETTLEMENT=$(json settlement); SHARE=$(json earnShare)
PROGRAM=$(json program)
SPENDER_ID=$(cast keccak smoke.card-program)
DEPLOYER_PK=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 0)
ALICE_PK=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 2)
ALICE=$(cast wallet address --private-key "$ALICE_PK")
BRIDGE_KEY_PK=$(cast keccak "smoke.bridge-key.$(date +%s).$RANDOM")
BRIDGE_KEY=$(cast wallet address --private-key "$BRIDGE_KEY_PK")
ATTACKER=0x000000000000000000000000000000000000dEaD
CARD_SPEND="(address,address,uint256,address,uint256,address,uint256,uint256,bytes32)"
PROGRAM_SPEND_SEL=$(cast sig "spend($CARD_SPEND)")
FACTORY=$(json factory)

balanceOf() { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$RPC" | awk '{print $1}'; }
balance() { balanceOf "$USD" "$1"; }
allowance() { cast call "$1" "allowance(address,address)(uint256)" "$2" "$3" --rpc-url "$RPC" | awk '{print $1}'; }
expect() { [[ "$2" == "$3" ]] || { echo "$1: expected $3, got $2"; exit 1; }; }

# Runs the command after `want`, which must fail with output naming `want` (an error selector or
# message), so a check cannot pass on an unrelated failure.
expect_revert() {
  local want=$1 out
  shift
  if out=$("$@" 2>&1); then echo "expected a revert with $want, but it succeeded"; exit 1; fi
  grep -qi -- "$want" <<<"$out" || { echo "expected a revert with $want, got: $out"; exit 1; }
}

# The TempoSpendExecuted log for `ref` on the clone, as "from amount fromStable fromVault", one line per
# log: the program pays through the clone, so it is the handler's payer.
TS_EXECUTED=$(cast keccak "TempoSpendExecuted(bytes32,address,address,address,uint256,uint256,uint256,uint256)")
executed() {
  cast logs --address "$CLONE" --from-block 0 --rpc-url "$RPC" --json "$TS_EXECUTED" "$(cast keccak "$1")" \
    | python3 -c "
import json, sys
for log in json.load(sys.stdin):
    words = [int(log['data'][2 + 64 * i : 66 + 64 * i], 16) for i in range(5)]
    payer = '0x' + log['topics'][2][-40:]
    print(payer, words[1], words[2], words[3])"
}

# The pulls LocalSmoke broadcast, read back from the node: EA 10, TS from Earn 25, TS split 20.
PROGRAM_LC=$(tr '[:upper:]' '[:lower:]' <<<"$PROGRAM")
expect "program spend from Earn" "$(executed smoke.auth.1)" "$PROGRAM_LC 25000000 0 25000000"
expect "program split spend" "$(executed smoke.auth.2)" "$PROGRAM_LC 20000000 5000000 15000000"
expect "settlement wallet" "$(balance "$SETTLEMENT")" 55000000
expect "Alice's stablecoin (1000 minted, 200 into Earn, 10 EA, 5 split)" "$(balance "$ALICE")" 785000000
expect "Alice's stablecoin allowance to the program" "$(allowance "$USD" "$ALICE" "$PROGRAM")" 0
expect "Alice's share allowance to the program" "$(allowance "$SHARE" "$ALICE" "$PROGRAM")" 0
expect "stablecoin left in the program" "$(balance "$PROGRAM")" 0
expect "shares left in the program" "$(balanceOf "$SHARE" "$PROGRAM")" 0
expect "stablecoin left in the clone" "$(balance "$CLONE")" 0
expect "shares left in the clone" "$(balanceOf "$SHARE" "$CLONE")" 0
echo "EA pull settled 10, program spend from Earn settled 25, program split spend settled 20"

# Fees are paid in the account's fee token and count against the key's limits unless a fee payer
# sponsors them, so the key gets a small budget in that token for gas.
FEE_TOKEN=$(cast call 0xFEEC000000000000000000000000000000000000 "userTokens(address)(address)" "$ALICE" --rpc-url "$RPC")
echo "authorize Bridge access key: 50 USD per 30 days, approve(program) and program.spend only"
APPROVE_SEL=$(cast sig "approve(address,uint256)")
EXPIRY=$(( $(date +%s) + 86400 ))
cast send 0xaAAAaaAA00000000000000000000000000000000 \
  "authorizeKey(address,uint8,(uint64,bool,(address,uint256,uint64)[],bool,(address,(bytes4,address[])[])[]))" \
  "$BRIDGE_KEY" 0 \
  "($EXPIRY,true,[($USD,50000000,2592000),($FEE_TOKEN,5000000,2592000)],false,[($USD,[($APPROVE_SEL,[$PROGRAM])]),($PROGRAM,[($PROGRAM_SPEND_SEL,[])])])" \
  --private-key "$ALICE_PK" --rpc-url "$RPC" >/dev/null

# Submits a program spend from Alice's account with Bridge's access key: approve the exact amount
# to the program, spend, approve zero. The program pays through the clone's "TS" handler.
spend() {
  local amount=$1 destination=$2 spend data
  spend="($PROGRAM,$USD,$amount,$destination,0,0x0000000000000000000000000000000000000000,0,0,0x0000000000000000000000000000000000000000000000000000000000000000)"
  data=$(cast calldata "spend($CARD_SPEND)" "$spend")
  cast batch-send \
    --call "$USD::approve(address,uint256):$PROGRAM,$amount" \
    --call "$PROGRAM::$data" \
    --call "$USD::approve(address,uint256):$PROGRAM,0" \
    --tempo.access-key "$BRIDGE_KEY_PK" --tempo.root-account "$ALICE" --rpc-url "$RPC"
}

before=$(balance "$SETTLEMENT")
spend 30000000 "$SETTLEMENT" >reports/smoke-spend.log 2>&1 || { cat reports/smoke-spend.log; exit 1; }
expect "access-key spend to the settlement wallet" "$(( $(balance "$SETTLEMENT") - before ))" 30000000
echo "access-key batch spend settled 30"

expect_revert "$(cast sig "DestinationNotAuthorized(address)")" spend 1000000 "$ATTACKER"
echo "access key cannot pay outside program destinations"

expect_revert "CallNotAllowed" cast send "$USD" "transfer(address,uint256)" "$ATTACKER" 1 \
  --tempo.access-key "$BRIDGE_KEY_PK" --tempo.root-account "$ALICE" --rpc-url "$RPC"
echo "access key cannot transfer to anyone"
expect_revert "CallNotAllowed" cast send "$CLONE" "publicCall(bytes)" 0x5453 \
  --tempo.access-key "$BRIDGE_KEY_PK" --tempo.root-account "$ALICE" --rpc-url "$RPC"
echo "access key cannot call the clone itself"

# Governance takes the program off the gated handler's allowlist: the key's spend to a program
# destination then stops at the factory's gate. The deployment scripts below put it back.
submit() { cast send "$FACTORY" "$1" --private-key "$DEPLOYER_PK" --rpc-url "$RPC" >/dev/null; }
submit "$(cast calldata "updateSpenderHandlerAllowlist(bytes2,bytes32,bool)" 0x5453 "$SPENDER_ID" false)"
expect_revert "$(cast sig "SpenderHandlerNotAllowed()")" spend 1000000 "$SETTLEMENT"
echo "access key cannot spend through a gated handler the program is not allowlisted for"

# Deploys a replacement "TS" handler with the deployment scripts, submits the calls they write
# with the roles the smoke deployer holds, and spends through it with the same access key. The
# factory already has a "TS" handler, so the script writes no gate call.
field() { python3 -c "import json,sys; v=json.load(open('$1'))['$2']; print(v if isinstance(v,str) else ' '.join(v))"; }
DEPLOYER_PK=$DEPLOYER_PK FACTORY=$FACTORY OUT=reports/deploy-tempo-spend.json \
  forge script script/bridge/deploy/DeployTempoSpend.s.sol --rpc-url "$RPC" --broadcast --slow >/dev/null 2>&1
submit "$(field reports/deploy-tempo-spend.json adminRegisterHandler)"
GATE=$(field reports/deploy-tempo-spend.json governanceGateHandler)
[[ "$GATE" == "0x" ]] || { echo "a replacement handler must not write a gate call"; exit 1; }
FACTORY=$FACTORY SPENDER_ID=$SPENDER_ID VAULTS=$(json earnVault) OUT=reports/program-calls.json \
  forge script script/bridge/deploy/ProgramCalls.s.sol --rpc-url "$RPC" >/dev/null 2>&1
submit "$(field reports/program-calls.json governanceAllowlistProgram)"
for call in $(field reports/program-calls.json governanceAllowVaults); do submit "$call"; done
rm -rf foundry-pp
HANDLER=$(field reports/deploy-tempo-spend.json handler)
expect "registered TS handler" "$(cast call "$FACTORY" "getSpenderHandler(bytes2)(address)" 0x5453 --rpc-url "$RPC")" "$HANDLER"
# Still gated: a clone governance never allowlisted is refused.
expect_revert "$(cast sig "SpenderHandlerNotAllowed()")" cast call "$FACTORY" \
  "getSpenderHandlerWithCheckedPermissions(bytes2,address)(address)" 0x5453 "$ATTACKER" --rpc-url "$RPC"
before=$(balance "$SETTLEMENT")
spend 10000000 "$SETTLEMENT" >reports/smoke-spend.log 2>&1 || { cat reports/smoke-spend.log; exit 1; }
expect "spend through the deployed handler" "$(( $(balance "$SETTLEMENT") - before ))" 10000000
echo "deployment scripts: replacement handler registered, still gated, program allowlisted again, spend settled 10"

expect_revert "SpendingLimitExceeded" spend 30000000 "$SETTLEMENT"
echo "access key stops at its 50 USD limit"

# The private path's contracts on a real node: the program's CardSpender, released with release.sh
# (the release CardFactory and BridgeProvider through the node's CREATE2 deployer, then
# CardFactory.deploy), and its Spend-mode ZoneRouter, deployed through a ZoneRouterFactory as
# script/bridge/deploy/DeployZoneRouter.s.sol does. The node runs no Zone, so this checks deployment,
# the router's fixed mode and its messenger gate; e2e/cards/bridge runs a private spend through them.
release() {
  DEPLOYER_PRIVATE_KEY=$DEPLOYER_PK TEMPO_RPC_URL=$RPC FACTORY=$FACTORY SPENDER_ID=$SPENDER_ID \
    RESULT=reports/smoke-release.json script/bridge/deploy/release.sh local bridgeProgram "$@" \
    >reports/smoke-release.log 2>&1 || { tail -40 reports/smoke-release.log; exit 1; }
}
rjson() { jq -r "$1" reports/smoke-release.json; }
release
expect "dry run: the program would be created" "$(rjson '.contracts | map(.existed) | join(",")')" "false,false,false"
release --broadcast
RELEASED=$(rjson .address)
expect "release created the program" "$(rjson '.contracts | map(.name) | join(",")')" "CardFactory,BridgeProvider,CardSpender"
CARD_FACTORY=$(rjson '.contracts[0].address')
PROVIDER=$(rjson '.contracts[1].address')
expect "release output names the program" "$(rjson '.output.program')" "$RELEASED"
release --broadcast
expect "a second release reuses all three" "$(rjson '.contracts | map(.existed) | join(",")')" "true,true,true"
rm -rf foundry-pp
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
expect "card factory deployed the program" "$(cast call "$CARD_FACTORY" "isSpender(address)(bool)" "$RELEASED" --rpc-url "$RPC")" true
expect "program's provider" "$(lower "$(cast call "$RELEASED" "PROVIDER()(address)" --rpc-url "$RPC")")" "$(lower "$PROVIDER")"
expect "program pays through the clone" "$(lower "$(cast call "$RELEASED" "PAYOUT_TARGET()(address)" --rpc-url "$RPC")")" "$(lower "$CLONE")"
expect "provider's program" "$(cast call "$PROVIDER" "SPENDER_ID()(bytes32)" --rpc-url "$RPC")" "$SPENDER_ID"
expect "provider's factory" "$(lower "$(cast call "$PROVIDER" "FACTORY()(address)" --rpc-url "$RPC")")" "$(lower "$FACTORY")"
expect "no guardian" "$(cast call "$RELEASED" "GUARDIAN()(address)" --rpc-url "$RPC")" 0x0000000000000000000000000000000000000000

create() {
  # Flags first: --constructor-args takes every argument after it.
  forge create --rpc-url "$RPC" --private-key "$DEPLOYER_PK" --broadcast "$@" 2>&1 | awk '/Deployed to:/ {print $3}'
}
ZERO=0x0000000000000000000000000000000000000000
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
MODE_T="(uint32,uint8,address,address,address,bytes32,address[])"
ROUTER_FACTORY=$(create ../zone-router/src/ZoneRouterFactory.sol:ZoneRouterFactory)
[[ -n "$ROUTER_FACTORY" ]] || { echo "router factory not deployed"; exit 1; }
MODE="(1,4,$ZERO,$ZERO,$ZERO,$ZERO32,[$RELEASED])"
cast send "$ROUTER_FACTORY" "deploy($MODE_T)" "$MODE" --private-key "$DEPLOYER_PK" --rpc-url "$RPC" >/dev/null
ROUTER=$(cast call "$ROUTER_FACTORY" "predict($MODE_T)(address)" "$MODE" --rpc-url "$RPC")
expect "router deployed by the factory" "$(cast call "$ROUTER_FACTORY" "isRouter(address)(bool)" "$ROUTER" --rpc-url "$RPC")" true
expect "router lists the program" "$(cast call "$ROUTER" "isSettler(address)(bool)" "$RELEASED" --rpc-url "$RPC")" true
expect "router takes Spend only" "$(cast call "$ROUTER" "enabledOps()(uint8)" --rpc-url "$RPC")" 4
expect_revert "$(cast sig "NotZoneMessenger()")" cast call "$ROUTER" \
  "onWithdrawalReceived(uint32,address,bytes32,address,uint128,bytes)(bytes4)" 1 "$ZERO" \
  $ZERO32 "$USD" 1 0x --rpc-url "$RPC"
echo "private path: program released with release.sh and reused, a Spend-mode router listing it, callbacks only from the Zone messenger"

echo "smoke: real-node checks passed"
