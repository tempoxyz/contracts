#!/usr/bin/env bash
# Deploys one of spend's ownerless contracts for a Bridge SpenderFactory at its deterministic
# release address (script/deploy/SpendRelease.sol), or reuses the one already there: the "TS"
# handler (tempoSpend) or one program's BridgeSettler (bridgeSettler). It checks that the run created
# exactly that contract, at the address predicted here from the locally compiled creation code, and,
# after a broadcast to a hosted network, that Tempo's verifier has its source. Bridge running the
# deploy scripts itself lands on the same address. The Spend Release workflow
# (.github/workflows/spend-release.yml) runs this; it runs locally too.
#
# Usage: script/deploy/release.sh <moderato|mainnet|local> <tempoSpend|bridgeSettler> [--broadcast]
# Env:   FACTORY               the Bridge SpenderFactory
#        SPENDER_ID            bridgeSettler only: the program's spender ID
#        DEPLOYER_PRIVATE_KEY  pays for the creation; it holds no role anywhere
#        TEMPO_RPC_URL         optional on moderato and mainnet, required for local; with
#                              TEMPO_RPC_USERNAME and TEMPO_RPC_PASSWORD (both or neither) as basic auth
#        RESULT                where to write the result JSON (default reports/spend-release.json);
#                              it never holds the key or the RPC credentials
set -euo pipefail
cd "$(dirname "$0")/../.."

readonly CREATE2_DEPLOYER=0x4e59b44847b379578588920ca78fbf26c0b4956c
readonly VERIFIER_URL=https://contracts.tempo.xyz
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
  echo "usage: $0 <moderato|mainnet|local> <tempoSpend|bridgeSettler> [--broadcast]" >&2
  exit 2
fi

result=${RESULT:-reports/spend-release.json}
mkdir -p "$(dirname "$result")"
result=$(cd "$(dirname "$result")" && pwd)/$(basename "$result")
# The scripts may write only under reports/ (foundry.toml's fs_permissions).
mkdir -p reports
out=$(mktemp -p reports spend-release-out.XXXXXX)
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
  tempoSpend) script=script/deploy/DeployTempoSpend.s.sol name=SpenderTempoSpend output_field=handler ;;
  bridgeSettler) script=script/deploy/DeployBridgeSettler.s.sol name=BridgeSettler output_field=settler ;;
  *) die "unknown contract '$contract'; expected tempoSpend or bridgeSettler" ;;
esac
source=$([[ "$contract" == tempoSpend ]] && echo src/SpenderTempoSpend.sol || echo src/settler/BridgeSettler.sol):$name
record name "$name"

[[ "${FACTORY:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "FACTORY must be an address"
record factory "$FACTORY"
if [[ "$contract" == bridgeSettler ]]; then
  [[ "${SPENDER_ID:-}" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "SPENDER_ID must be a bytes32 for bridgeSettler"
  record spenderId "$SPENDER_ID"
  constructor_args=$(cast abi-encode "f(address,bytes32)" "$FACTORY" "$SPENDER_ID")
else
  [[ -z "${SPENDER_ID:-}" ]] || die "SPENDER_ID is only for bridgeSettler"
  constructor_args=$(cast abi-encode "f(address)" "$FACTORY")
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
# Forge runs the chain's current Tempo hardfork, as docs/spend/deploy.md says.
active=$(cast rpc tempo_forkSchedule | jq -r '.active // empty') || die "tempo_forkSchedule failed"
[[ -n "$active" ]] || die "tempo_forkSchedule has no active hardfork"
export FOUNDRY_HARDFORK="tempo:$active"
record hardfork "$FOUNDRY_HARDFORK"
[[ "$(cast code "$CREATE2_DEPLOYER")" != 0x ]] || die "the chain has no CREATE2 deployer at $CREATE2_DEPLOYER"
[[ "$(cast code "$FACTORY")" != 0x ]] || die "FACTORY has no code"

# The deterministic address, from this checkout's compiled creation code.
creation=$(env -u DEPLOYER_PRIVATE_KEY forge inspect "$source" bytecode)
[[ "$creation" =~ ^0x[0-9a-fA-F]+$ ]] || die "forge returned no creation code for $source"
init_code=$(tr '[:upper:]' '[:lower:]' <<<"${creation}${constructor_args#0x}")
init_hash=$(cast keccak "$init_code")
hash=$(cast keccak "0xff${CREATE2_DEPLOYER#0x}${RELEASE_SALT#0x}${init_hash#0x}")
address=$(cast to-check-sum-address "0x${hash:26:40}")
record address "$address"
existed=false
[[ "$(cast code "$address")" == 0x ]] || existed=true
record --json existed "$existed"

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
DEPLOYER_PK=$DEPLOYER_PRIVATE_KEY OUT=$out forge "${forge_args[@]}" || forge_status=$?
record --json forgeStatus "$forge_status"
[[ "$forge_status" == 0 || -f "$sequence" ]] || die "forge script failed (status $forge_status)"

# The run must have created exactly the missing contract, at its address, from its creation code.
transaction=null
creations='[]'
[[ ! -f "$sequence" ]] ||
  creations=$(jq -c '[.transactions[]? | select((.transactionType // "") | startswith("CREATE"))]' "$sequence")
if [[ "$existed" == true ]]; then
  [[ "$(jq length <<<"$creations")" == 0 ]] || die "$name already existed at $address, but the run created a contract"
else
  [[ "$(jq length <<<"$creations")" == 1 ]] ||
    die "the run created $(jq length <<<"$creations") contracts, expected $name alone"
  created=$(jq -c '.[0]' <<<"$creations")
  [[ "$(jq -r '.contractName' <<<"$created")" == "$name" ]] ||
    die "the run created $(jq -r '.contractName' <<<"$created"), expected $name"
  [[ "$(jq -r '.contractAddress // "" | ascii_downcase' <<<"$created")" == "${address,,}" ]] ||
    die "$name was created at $(jq -r '.contractAddress' <<<"$created"), not its deterministic address $address"
  # The CREATE2 deployer's calldata is the salt followed by the creation code.
  [[ "$(jq -r '.transaction.input // .transaction.data // "" | ascii_downcase' <<<"$created")" == "${RELEASE_SALT}${init_code#0x}" ]] ||
    die "$name creation input is not the release salt and its locally compiled creation code"
  if [[ "$broadcast" == true ]]; then
    transaction=$(jq -r '.hash' <<<"$created")
    receipt=$(jq -r --arg hash "${transaction,,}" \
      '[.receipts[]? | select((.transactionHash // "" | ascii_downcase) == $hash) | .status][0] // ""' "$sequence")
    [[ "$receipt" == 0x1 ]] || die "$name creation $transaction has no successful receipt"
    record transaction "$transaction"
  fi
fi
if [[ "$broadcast" == true ]]; then
  [[ -f "$out" ]] || die "forge script failed (status $forge_status) before writing its output"
  record --json output "$(cat "$out")"
  [[ "$(jq -r --arg field "$output_field" '.[$field] | ascii_downcase' "$out")" == "${address,,}" ]] ||
    die "the script's $output_field is not the deterministic address $address"
  [[ "$(cast code "$address")" != 0x ]] || die "$address has no code after the broadcast"
elif [[ "$forge_status" != 0 ]]; then
  die "forge script failed (status $forge_status)"
elif [[ "$contract" == tempoSpend ]]; then
  # A dry run writes no OUT; the admin call depends only on the address.
  record --json output "$(jq -n --arg call "$(cast calldata "setSpenderHandler(bytes2,address)" 0x5453 "$address")" \
    '{adminRegisterHandler: $call}')"
fi

# Tempo's verifier must hold the source of the broadcast contract, also one that already existed,
# which forge's --verify skips.
lookup() {
  curl -fsS "$VERIFIER_URL/v2/contract/$chain_id/$address?fields=all" 2>/dev/null |
    jq -r --arg name "$name" 'if .match and ((.name // .compilation.name // $name) == $name) then .match else empty end' ||
    true
}
if [[ "$broadcast" == true && "$hosted" == true ]]; then
  match=$(lookup)
  if [[ -z "$match" ]]; then
    verify_args=("$address" "$source" --chain "$chain_id" --verifier sourcify --verifier-url "$VERIFIER_URL"
      --constructor-args "$constructor_args" --skip-is-verified-check)
    [[ "$transaction" == null ]] || verify_args+=(--creation-transaction-hash "$transaction")
    env -u DEPLOYER_PRIVATE_KEY forge verify-contract "${verify_args[@]}" || true
    for _ in $(seq 1 24); do
      match=$(lookup)
      [[ -z "$match" ]] || break
      sleep 5
    done
  fi
  [[ -n "$match" ]] || die "$name $address is deployed, but $VERIFIER_URL has no source match for it"
  record match "$match"
fi
[[ "$broadcast" == true || "$existed" == true ]] || outcome='would be created'
[[ "$broadcast" == false || "$existed" == true ]] || outcome=created
[[ "$existed" == false ]] || outcome='already deployed'
echo "release: $name at $address ($outcome)"
