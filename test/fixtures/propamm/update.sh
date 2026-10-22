#!/usr/bin/env bash
# Rebuilds the committed DirectPropAMM fixture from the tempoxyz/propAMM commit in source.json.
#
# Usage: test/fixtures/propamm/update.sh [--check] [<propAMM checkout>]
#
# Without a checkout path, clones tempoxyz/propAMM into a temporary directory with the caller's Git
# credentials. A given checkout must be clean and at the pinned commit. `--check` rewrites nothing and
# exits non-zero when the committed fixture differs from the build. Requires git, forge, and jq.
set -euo pipefail

fixture_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fixture="$fixture_dir/DirectPropAMM.json"
source_json="$fixture_dir/source.json"

check=false
checkout=''
for arg in "$@"; do
  case "$arg" in
    --check) check=true ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)
      [[ -z "$checkout" ]] || { echo "expected at most one propAMM checkout path" >&2; exit 2; }
      checkout=$arg
      ;;
  esac
done

repository=$(jq -er '.repository' "$source_json")
commit=$(jq -er '.commit' "$source_json")
contract=$(jq -er '.contract' "$source_json")
solc=$(jq -er '.solc' "$source_json")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "source.json commit is not a full SHA: $commit" >&2; exit 1; }
source_path=${contract%%:*}
contract_name=${contract##*:}

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if [[ -z "$checkout" ]]; then
  checkout="$scratch/propAMM"
  git init --quiet "$checkout"
  git -C "$checkout" fetch --quiet --depth 1 "https://github.com/$repository.git" "$commit"
  git -C "$checkout" checkout --quiet --detach FETCH_HEAD
fi

head=$(git -C "$checkout" rev-parse HEAD)
[[ "$head" == "$commit" ]] || { echo "$checkout is at $head, expected $commit" >&2; exit 1; }
[[ -z "$(git -C "$checkout" status --porcelain --untracked-files=no)" ]] || {
  echo "$checkout has uncommitted changes" >&2
  exit 1
}

git -C "$checkout" submodule update --quiet --init --depth 1
# Forge also lints the PropAMM sources on build; show its output only when the build fails.
forge build --root "$checkout" --skip test --skip script >"$scratch/forge.log" 2>&1 || {
  cat "$scratch/forge.log" >&2
  exit 1
}

artifact="$checkout/out/$(basename "$source_path")/$contract_name.json"
built_target=$(jq -er --arg path "$source_path" '.metadata.settings.compilationTarget[$path]' "$artifact")
[[ "$built_target" == "$contract_name" ]] || { echo "$artifact does not compile $contract" >&2; exit 1; }
built_solc=$(jq -er '.metadata.compiler.version' "$artifact")
[[ "$built_solc" == "$solc+"* ]] || { echo "built with solc $built_solc, expected $solc" >&2; exit 1; }
# The fixture keeps no link references, so the bytecode must need none.
jq -e '(.bytecode.linkReferences | length) == 0 and (.deployedBytecode.linkReferences | length) == 0' \
  "$artifact" >/dev/null || { echo "$contract needs library linking" >&2; exit 1; }

jq '{abi, bytecode: {object: .bytecode.object}, deployedBytecode: {object: .deployedBytecode.object}}' \
  "$artifact" >"$scratch/DirectPropAMM.json"

if [[ "$check" == true ]]; then
  if ! cmp -s "$scratch/DirectPropAMM.json" "$fixture"; then
    echo "$fixture does not match $repository@$commit; run $0 to regenerate it" >&2
    exit 1
  fi
  echo "$fixture matches $repository@$commit"
else
  mv "$scratch/DirectPropAMM.json" "$fixture"
  echo "wrote $fixture from $repository@$commit"
fi
