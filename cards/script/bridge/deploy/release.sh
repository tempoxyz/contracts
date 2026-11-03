#!/usr/bin/env bash
# Deploys the card integration's ownerless contracts for a SpenderFactory at their deterministic
# addresses, or reuses those already there: the "TS" handler (tempoSpend), at its release address
# (script/bridge/deploy/BridgeRelease.sol), or a Bridge card program's CardProgram (bridgeProgram):
# the release CardFactory and the program's BridgeIssuer, each at its release address, and the
# program, which that CardFactory creates at the address its program ID (the spender ID), issuer and
# guardian fix. It checks that the run created exactly the missing contracts, each at the address
# predicted here from the locally compiled creation code, and, after a broadcast to a hosted
# network, that Tempo's verifier has the source of every one. Bridge running the deploy scripts
# itself lands on the same addresses. The Bridge Release workflow
# (.github/workflows/bridge-release.yml) runs this; it runs locally too.
#
# Usage: script/bridge/deploy/release.sh <moderato|mainnet|local> <tempoSpend|bridgeProgram> [--broadcast]
# Env:   FACTORY               the SpenderFactory
#        SPENDER_ID            bridgeProgram only: the card program's spender ID (bytes32)
#        GUARDIAN              bridgeProgram only, optional: the account that can pause the program;
#                              zero or unset for none
#        DEPLOYER_PRIVATE_KEY  pays for the creation; it holds no role anywhere
#        TEMPO_RPC_URL         optional on moderato and mainnet, required for local; with
#                              TEMPO_RPC_USERNAME and TEMPO_RPC_PASSWORD (both or neither) as basic auth
#        RESULT                where to write the result JSON (default reports/bridge-release.json);
#                              it never holds the key or the RPC credentials
set -euo pipefail
cd "$(dirname "$0")/../../.."

readonly CREATE2_DEPLOYER=0x4e59b44847b379578588920ca78fbf26c0b4956c
readonly VERIFIER_URL=https://contracts.tempo.xyz
readonly ZERO_ADDRESS=0x0000000000000000000000000000000000000000
# Earn's release salt (earn/script/deploy/DeterministicRelease.sol), predicted independently of the
# scripts, so a drift between the two fails the release instead of hiding it.
RELEASE_SALT=$(cast keccak "tempoxyz/earn shared factory release")
readonly RELEASE_SALT

network=${1:-}
contract=${2:-}
broadcast=false
if [[ $# -eq 3 && "$3" == --broadcast ]]; then
  broadcast=true
elif [[ $# -ne 2 ]]; then
  echo "usage: $0 <moderato|mainnet|local> <tempoSpend|bridgeProgram> [--broadcast]" >&2
  exit 2
fi

result=${RESULT:-reports/bridge-release.json}
mkdir -p "$(dirname "$result")"
result=$(cd "$(dirname "$result")" && pwd)/$(basename "$result")
# The scripts may write only under reports/ (foundry.toml's fs_permissions).
mkdir -p reports
out=$(mktemp -p reports bridge-release-out.XXXXXX)
rm -f "$out"
state='{}'
# Records a field of the result: a string, or with --json a JSON value.
record() {
  if [[ "$1" == --json ]]; then
    state=$(jq --arg key "$2" --argjson value "$3" '.[$key] = $value' <<<"$state")
  else
    state=$(jq --arg key "$1" --arg value "$2" '.[$key] = $value' <<<"$state")
  fi
  printf '%s\n' "$state" >"$result"
}
# Sets a field of the i-th entry of .contracts.
record_contract() {
  state=$(jq --argjson i "$1" --arg key "$2" --argjson value "$3" '.contracts[$i][$key] = $value' <<<"$state")
  printf '%s\n' "$state" >"$result"
}
die() {
  record error "$*"
  echo "release: $*" >&2
  exit 1
}
# Forge records the RPC URL, with its credentials, in its script sequences under cache/.
cleanup() {
  find cache -mindepth 1 -maxdepth 2 -type d -name '*.s.sol' -exec rm -rf {} + 2>/dev/null || true
  rm -f "$out"
}
trap cleanup EXIT

record network "$network"
record contract "$contract"
record --json broadcast "$broadcast"
record commit "$(git rev-parse HEAD 2>/dev/null || echo unknown)"

case "$network" in
  moderato) chain_id=42431 default_rpc=https://rpc.moderato.tempo.xyz hosted=true ;;
  mainnet) chain_id=4217 default_rpc=https://rpc.tempo.xyz hosted=true ;;
  local) chain_id='' default_rpc='' hosted=false ;;
  *) die "unknown network '$network'; expected moderato, mainnet or local" ;;
esac
case "$contract" in
  tempoSpend) script=script/bridge/deploy/DeployTempoSpend.s.sol ;;
  bridgeProgram) script=script/bridge/deploy/DeployBridgeProgram.s.sol ;;
  *) die "unknown contract '$contract'; expected tempoSpend or bridgeProgram" ;;
esac

[[ "${FACTORY:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "FACTORY must be an address"
record factory "$FACTORY"
if [[ "$contract" == bridgeProgram ]]; then
  [[ "${SPENDER_ID:-}" =~ ^0x[0-9a-fA-F]{64}$ && ! "$SPENDER_ID" =~ ^0x0{64}$ ]] ||
    die "SPENDER_ID must be a nonzero bytes32"
  record spenderId "$SPENDER_ID"
  guardian=${GUARDIAN:-$ZERO_ADDRESS}
  [[ "$guardian" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "GUARDIAN must be an address, or unset for none"
  record guardian "$guardian"
fi
[[ -n "${DEPLOYER_PRIVATE_KEY:-}" ]] || die "DEPLOYER_PRIVATE_KEY is required"

# The RPC URL with its basic-auth credentials, given to forge and cast only through the environment.
rpc_lines=$(python3 - "$default_rpc" <<'EOF'
import os, sys, urllib.parse
raw = os.environ.get("TEMPO_RPC_URL") or sys.argv[1]
if not raw:
    sys.exit("TEMPO_RPC_URL is required for local")
url = urllib.parse.urlsplit(raw)
user = os.environ.get("TEMPO_RPC_USERNAME") or urllib.parse.unquote(url.username or "")
password = os.environ.get("TEMPO_RPC_PASSWORD") or urllib.parse.unquote(url.password or "")
if bool(user) != bool(password):
    sys.exit("TEMPO_RPC_USERNAME and TEMPO_RPC_PASSWORD must be configured together")
host = url.netloc.rpartition("@")[2]
user, password = urllib.parse.quote(user, safe=""), urllib.parse.quote(password, safe="")
netloc = f"{user}:{password}@{host}" if user else host
print(urllib.parse.urlunsplit((url.scheme, netloc, url.path, url.query, url.fragment)))
print(user)
print(password)
EOF
) || die "invalid RPC configuration"
mapfile -t rpc <<<"$rpc_lines"
unset rpc_lines
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  for secret in "${rpc[@]}"; do [[ -z "$secret" ]] || echo "::add-mask::$secret"; done
fi
# cast reads ETH_RPC_URL; forge script and verify-contract read FOUNDRY_ETH_RPC_URL.
export ETH_RPC_URL=${rpc[0]} FOUNDRY_ETH_RPC_URL=${rpc[0]}
unset rpc

actual_chain_id=$(cast chain-id) || die "the RPC did not answer"
if [[ -z "$chain_id" ]]; then
  chain_id=$actual_chain_id
elif [[ "$actual_chain_id" != "$chain_id" ]]; then
  die "the RPC serves chain $actual_chain_id, not $network ($chain_id)"
fi
record --json chainId "$chain_id"
# Forge runs the chain's current Tempo hardfork, as docs/cards/bridge/deploy.md says.
active=$(cast rpc tempo_forkSchedule | jq -r '.active // empty') || die "tempo_forkSchedule failed"
[[ -n "$active" ]] || die "tempo_forkSchedule has no active hardfork"
export FOUNDRY_HARDFORK="tempo:$active"
record hardfork "$FOUNDRY_HARDFORK"
[[ "$(cast code "$CREATE2_DEPLOYER")" != 0x ]] || die "the chain has no CREATE2 deployer at $CREATE2_DEPLOYER"
[[ "$(cast code "$FACTORY")" != 0x ]] || die "FACTORY has no code"

# The contracts this release consists of, in creation order: name, source, the field of the script's
# OUT holding its address, ABI-encoded constructor arguments, and who creates it (the CREATE2
# deployer, or the CardFactory's deploy call).
names=() sources=() fields=() args=() creators=() addresses=() inits=()
add() { names+=("$1") sources+=("$2") fields+=("$3") args+=("$4") creators+=("$5"); }
if [[ "$contract" == tempoSpend ]]; then
  add SpenderTempoSpend src/providers/bridge/SpenderTempoSpend.sol:SpenderTempoSpend handler \
    "$(cast abi-encode "f(address)" "$FACTORY")" deployer
else
  add CardFactory src/core/CardFactory.sol:CardFactory cardFactory 0x deployer
  add BridgeIssuer src/providers/bridge/BridgeIssuer.sol:BridgeIssuer issuer \
    "$(cast abi-encode "f(address,bytes32)" "$FACTORY" "$SPENDER_ID")" deployer
  add CardProgram src/core/CardProgram.sol:CardProgram program '' cardFactory
fi

# Each address, from this checkout's compiled creation code.
create2() { cast to-check-sum-address "0x$(cast keccak "0xff${1#0x}${2#0x}${3#0x}" | cut -c27-66)"; }
for i in "${!names[@]}"; do
  creation=$(env -u DEPLOYER_PRIVATE_KEY forge inspect "${sources[$i]}" bytecode)
  [[ "$creation" =~ ^0x[0-9a-fA-F]+$ ]] || die "forge returned no creation code for ${sources[$i]}"
  if [[ "${names[$i]}" == CardProgram ]]; then
    # CardFactory.deploy: salt keccak256(abi.encode(programId, issuer, guardian)), under the factory.
    args[i]=$(cast abi-encode "f(address,address)" "${addresses[1]}" "$guardian")
    inits[i]=$(tr '[:upper:]' '[:lower:]' <<<"${creation}${args[$i]#0x}")
    salt=$(cast keccak "$(cast abi-encode "f(bytes32,address,address)" "$SPENDER_ID" "${addresses[1]}" "$guardian")")
    addresses[i]=$(create2 "${addresses[0]}" "$salt" "$(cast keccak "${inits[$i]}")")
  else
    inits[i]=$(tr '[:upper:]' '[:lower:]' <<<"${creation}${args[$i]#0x}")
    addresses[i]=$(create2 "$CREATE2_DEPLOYER" "$RELEASE_SALT" "$(cast keccak "${inits[$i]}")")
  fi
  existed=false
  [[ "$(cast code "${addresses[$i]}")" == 0x ]] || existed=true
  record_contract "$i" name "$(jq -n --arg v "${names[$i]}" '$v')"
  record_contract "$i" address "$(jq -n --arg v "${addresses[$i]}" '$v')"
  record_contract "$i" existed "$existed"
done
# The release's own contract: the handler, or the program.
last=$((${#names[@]} - 1))
record name "${names[$last]}"
record address "${addresses[$last]}"
record --json existed "$(jq ".contracts[$last].existed" <<<"$state")"

forge_args=(script "$script" --network tempo --slow)
if [[ "$broadcast" == true ]]; then
  forge_args+=(--broadcast)
  [[ "$hosted" == false ]] || forge_args+=(--verify --verifier sourcify --verifier-url "$VERIFIER_URL")
fi
# Forge's sequence of this run, which a stale one from an earlier run must not stand in for.
sequence=broadcast/$(basename "$script")/$chain_id/$([[ "$broadcast" == true ]] || echo dry-run/)run-latest.json
rm -f "$sequence"
# A verification failure after the broadcast is handled below, so the status is kept rather than fatal.
forge_status=0
# The scripts read the key from DEPLOYER_PK; it goes through the environment, never the command line.
DEPLOYER_PK=$DEPLOYER_PRIVATE_KEY GUARDIAN=${guardian:-$ZERO_ADDRESS} OUT=$out forge "${forge_args[@]}" || forge_status=$?
record --json forgeStatus "$forge_status"
[[ "$forge_status" == 0 || -f "$sequence" ]] || die "forge script failed (status $forge_status)"

# The run must have sent exactly the transactions the missing contracts need: a CREATE2 through the
# deployer for each missing release contract, from its creation code, and the CardFactory's deploy
# call for a missing program.
transactions='[]'
[[ ! -f "$sequence" ]] || transactions=$(jq -c '[.transactions[]?]' "$sequence")
expected=0
for i in "${!names[@]}"; do
  name=${names[$i]} address=${addresses[$i]}
  [[ "$(jq ".contracts[$i].existed" <<<"$state")" == false ]] || continue
  expected=$((expected + 1))
  if [[ "${creators[$i]}" == deployer ]]; then
    sent=$(jq -c --arg name "$name" --arg address "${address,,}" \
      '[.[] | select(((.transactionType // "") | startswith("CREATE")) and .contractName == $name and ((.contractAddress // "") | ascii_downcase) == $address)]' <<<"$transactions")
    [[ "$(jq length <<<"$sent")" == 1 ]] || die "the run did not create $name at its deterministic address $address"
    # The CREATE2 deployer's calldata is the salt followed by the creation code.
    [[ "$(jq -r '.[0].transaction.input // .[0].transaction.data // "" | ascii_downcase' <<<"$sent")" == "${RELEASE_SALT}${inits[$i]#0x}" ]] ||
      die "$name creation input is not the release salt and its locally compiled creation code"
  else
    call=$(cast calldata "deploy(bytes32,address,address)" "$SPENDER_ID" "${addresses[1]}" "$guardian")
    sent=$(jq -c --arg to "${addresses[0],,}" --arg input "${call,,}" \
      '[.[] | select(((.transaction.to // "") | ascii_downcase) == $to and ((.transaction.input // .transaction.data // "") | ascii_downcase) == $input)]' <<<"$transactions")
    [[ "$(jq length <<<"$sent")" == 1 ]] || die "the run did not call CardFactory.deploy for the program"
  fi
  if [[ "$broadcast" == true ]]; then
    transaction=$(jq -r '.[0].hash' <<<"$sent")
    receipt=$(jq -r --arg hash "${transaction,,}" \
      '[.receipts[]? | select((.transactionHash // "" | ascii_downcase) == $hash) | .status][0] // ""' "$sequence")
    [[ "$receipt" == 0x1 ]] || die "$name creation $transaction has no successful receipt"
    record_contract "$i" transaction "$(jq -n --arg v "$transaction" '$v')"
  fi
done
[[ "$(jq length <<<"$transactions")" == "$expected" ]] ||
  die "the run sent $(jq length <<<"$transactions") transactions, expected $expected for the missing contracts"

if [[ "$broadcast" == true ]]; then
  [[ -f "$out" ]] || die "forge script failed (status $forge_status) before writing its output"
  record --json output "$(cat "$out")"
  for i in "${!names[@]}"; do
    [[ "$(jq -r --arg field "${fields[$i]}" '.[$field] | ascii_downcase' "$out")" == "${addresses[$i],,}" ]] ||
      die "the script's ${fields[$i]} is not the deterministic address ${addresses[$i]}"
    [[ "$(cast code "${addresses[$i]}")" != 0x ]] || die "${addresses[$i]} has no code after the broadcast"
  done
elif [[ "$forge_status" != 0 ]]; then
  die "forge script failed (status $forge_status)"
elif [[ "$contract" == tempoSpend ]]; then
  # A dry run writes no OUT; the admin call depends only on the address.
  record --json output "$(jq -n --arg call "$(cast calldata "setSpenderHandler(bytes2,address)" 0x5453 "${addresses[0]}")" \
    '{adminRegisterHandler: $call}')"
fi

# Tempo's verifier must hold the source of every broadcast contract, also one that already existed,
# which forge's --verify skips.
lookup() {
  curl -fsS "$VERIFIER_URL/v2/contract/$chain_id/$1?fields=all" 2>/dev/null |
    jq -r --arg name "$2" 'if .match and ((.name // .compilation.name // $name) == $name) then .match else empty end' ||
    true
}
if [[ "$broadcast" == true && "$hosted" == true ]]; then
  for i in "${!names[@]}"; do
    name=${names[$i]} address=${addresses[$i]}
    match=$(lookup "$address" "$name")
    if [[ -z "$match" ]]; then
      verify_args=("$address" "${sources[$i]}" --chain "$chain_id" --verifier sourcify --verifier-url "$VERIFIER_URL"
        --skip-is-verified-check)
      [[ "${args[$i]}" == 0x ]] || verify_args+=(--constructor-args "${args[$i]}")
      transaction=$(jq -r ".contracts[$i].transaction // empty" <<<"$state")
      [[ -z "$transaction" ]] || verify_args+=(--creation-transaction-hash "$transaction")
      env -u DEPLOYER_PRIVATE_KEY forge verify-contract "${verify_args[@]}" || true
      for _ in $(seq 1 24); do
        match=$(lookup "$address" "$name")
        [[ -z "$match" ]] || break
        sleep 5
      done
    fi
    [[ -n "$match" ]] || die "$name $address is deployed, but $VERIFIER_URL has no source match for it"
    record_contract "$i" match "$(jq -n --arg v "$match" '$v')"
  done
  record match "$(jq -r ".contracts[$last].match" <<<"$state")"
fi
for i in "${!names[@]}"; do
  existed=$(jq ".contracts[$i].existed" <<<"$state")
  if [[ "$existed" == true ]]; then outcome='already deployed'
  elif [[ "$broadcast" == true ]]; then outcome=created
  else outcome='would be created'; fi
  echo "release: ${names[$i]} at ${addresses[$i]} ($outcome)"
done
