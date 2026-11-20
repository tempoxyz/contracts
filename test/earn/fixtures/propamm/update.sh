#!/usr/bin/env bash
# Rebuilds a committed PropAMM fixture from the tempoxyz/tempo-propamm commit its source file pins: the
# DirectPropAMM fixture from source.json by default, or the fixture of the source file `--source` names
# (managed.source.json for ManagedDirectPropAMM). Each fixture is named after its contract.
#
# Usage: test/earn/fixtures/propamm/update.sh [--check] [--source <file>] [<tempo-propamm checkout>]
#
# Without a checkout path, fetches the pinned commit of the public tempoxyz/tempo-propamm anonymously over
# HTTPS into a temporary directory and requires it to be on that repository's main branch. A given checkout must be clean and at the pinned commit. `--check`
# rewrites nothing and exits non-zero when the committed fixture differs from the build. Requires git,
# forge, and jq.
set -euo pipefail

fixture_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_json="$fixture_dir/source.json"

check=false
checkout=''
while (($# > 0)); do
  arg=$1
  shift
  case "$arg" in
    --check) check=true ;;
    --source)
      (($# > 0)) || { echo "--source needs a file name" >&2; exit 2; }
      # Only a source file beside this script is accepted, by name.
      source_json="$fixture_dir/$(basename "$1")"
      shift
      ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)
      [[ -z "$checkout" ]] || { echo "expected at most one tempo-propamm checkout path" >&2; exit 2; }
      checkout=$arg
      ;;
  esac
done

[[ -f "$source_json" ]] || { echo "no source file $source_json" >&2; exit 2; }
repository=$(jq -er '.repository' "$source_json")
commit=$(jq -er '.commit' "$source_json")
contract=$(jq -er '.contract' "$source_json")
solc=$(jq -er '.solc' "$source_json")
[[ "$solc" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "$source_json solc is not a release version: $solc" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "$source_json commit is not a full SHA: $commit" >&2; exit 1; }
# Only the upstream repository is accepted, so a source.json edit cannot point the check elsewhere.
upstream=tempoxyz/tempo-propamm
[[ "$repository" == "$upstream" ]] || { echo "$source_json repository must be $upstream, got $repository" >&2; exit 1; }
source_path=${contract%%:*}
contract_name=${contract##*:}
[[ "$contract_name" =~ ^[A-Za-z0-9_]+$ ]] || { echo "$source_json contract is not <path>:<name>: $contract" >&2; exit 1; }
fixture="$fixture_dir/$contract_name.json"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if [[ -z "$checkout" ]]; then
  checkout="$scratch/propAMM"
  git init --quiet "$checkout"
  git -C "$checkout" fetch --quiet --depth 1 "https://github.com/$repository.git" "$commit"
  git -C "$checkout" checkout --quiet --detach FETCH_HEAD
  # GitHub serves commits pushed to forks from the parent's URL too, so require the pinned commit to be
  # on upstream main rather than trusting the fetch alone.
  git -C "$checkout" fetch --quiet --unshallow "https://github.com/$repository.git" refs/heads/main
  git -C "$checkout" merge-base --is-ancestor "$commit" FETCH_HEAD || {
    echo "$commit is not on $repository main" >&2
    exit 1
  }
fi

head=$(git -C "$checkout" rev-parse HEAD)
[[ "$head" == "$commit" ]] || { echo "$checkout is at $head, expected $commit" >&2; exit 1; }
[[ -z "$(git -C "$checkout" status --porcelain --untracked-files=no)" ]] || {
  echo "$checkout has uncommitted changes" >&2
  exit 1
}

git -C "$checkout" submodule update --quiet --init --depth 1
# The deployed pools are built with solc, so build with the solc version the source file names
# rather than the source repository's default compiler, into scratch output and cache directories so
# no artifact the checkout already holds is reused. Forge also lints the PropAMM sources on build;
# show its output only when the build fails.
forge build --root "$checkout" --use "$solc" --out "$scratch/out" --cache-path "$scratch/cache"   --skip test --skip script >"$scratch/forge.log" 2>&1 || {
  cat "$scratch/forge.log" >&2
  exit 1
}

artifact="$scratch/out/$(basename "$source_path")/$contract_name.json"
built_target=$(jq -er --arg path "$source_path" '.metadata.settings.compilationTarget[$path]' "$artifact")
[[ "$built_target" == "$contract_name" ]] || { echo "$artifact does not compile $contract" >&2; exit 1; }
built_solc=$(jq -er '.metadata.compiler.version' "$artifact")
[[ "$built_solc" == "$solc+"* ]] || { echo "built with solc $built_solc, expected $solc" >&2; exit 1; }
# The fixture keeps no link references, so the bytecode must need none.
jq -e '(.bytecode.linkReferences | length) == 0 and (.deployedBytecode.linkReferences | length) == 0' \
  "$artifact" >/dev/null || { echo "$contract needs library linking" >&2; exit 1; }

jq '{abi, bytecode: {object: .bytecode.object}, deployedBytecode: {object: .deployedBytecode.object}}' \
  "$artifact" >"$scratch/fixture.json"

if [[ "$check" == true ]]; then
  if ! cmp -s "$scratch/fixture.json" "$fixture"; then
    echo "$fixture does not match $repository@$commit; run $0 to regenerate it" >&2
    exit 1
  fi
  echo "$fixture matches $repository@$commit"
else
  mv "$scratch/fixture.json" "$fixture"
  echo "wrote $fixture from $repository@$commit"
fi
