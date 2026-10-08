# shellcheck shell=bash

set -euo pipefail

if (($# > 1)) || [[ "${1:-}" != "" && "${1:-}" != "--force" ]]; then
	echo 'Usage: update-fastflowlm [--force]' >&2
	exit 1
fi

root="$(git rev-parse --show-toplevel)"
current="$(nix eval --json "${root}#packages.x86_64-linux.fastflowlm" --apply 'p: { inherit (p) version; tokenizersVersion = p.tokenizers-cpp.version; inherit (p.tokenizers-cpp.src) rev; hash = p.tokenizers-cpp.src.outputHash; }')"
tag="$(gh api repos/ROCm/FastFlowLM/releases/latest --jq .tag_name)"
if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Unexpected FastFlowLM release tag: ${tag}" >&2
	exit 1
fi
version="${tag#v}"
if [[ "${version}" == "$(jq -r .version <<<"${current}")" && "${1:-}" != "--force" ]]; then
	echo "FastFlowLM is already on ${version}." >&2
	exit 0
fi

revision="$(gh api "repos/ROCm/FastFlowLM/contents/third_party/tokenizers-cpp?ref=${tag}" --jq .sha)"
if [[ ! "${revision}" =~ ^[0-9a-f]{40}$ ]]; then
	echo "Unexpected tokenizer revision: ${revision}" >&2
	exit 1
fi
date="$(gh api "repos/mlc-ai/tokenizers-cpp/commits/${revision}" --jq '.commit.committer.date[:10]')"
prefetched="$(nix flake prefetch --json "github:mlc-ai/tokenizers-cpp/${revision}")"
hash="$(jq -er .hash <<<"${prefetched}")"
source="$(jq -er .storePath <<<"${prefetched}")"

backup="$(mktemp -d)"
cp package.nix "${backup}/"
cp -r tokenizers-cpp "${backup}/"
cleanup() {
	status="$?"
	if ((status != 0)); then
		cp "${backup}/package.nix" "${root}/pkgs/fastflowlm/"
		cp "${backup}/tokenizers-cpp/default.nix" "${backup}/tokenizers-cpp/Cargo.lock" "${root}/pkgs/fastflowlm/tokenizers-cpp/"
	fi
	rm -rf "${backup}"
}
trap cleanup EXIT

cp -r "${source}/rust" "${backup}/rust"
chmod -R u+w "${backup}/rust"
cp tokenizers-cpp/Cargo.lock "${backup}/rust/"
(
	cd "${backup}/rust"
	cargo generate-lockfile
)

python3 - "${current}" "${revision}" "${date}" "${hash}" <<'PY'
import json
import sys
from pathlib import Path

current = json.loads(sys.argv[1])
revision, date, source_hash = sys.argv[2:]
version = current['tokenizersVersion'].split('-unstable-')[0] + '-unstable-' + date
package = Path('tokenizers-cpp/default.nix')
text = package.read_text()
for key, before, after in [
    ('version', current['tokenizersVersion'], version),
    ('rev', current['rev'], revision),
    ('hash', current['hash'], source_hash),
]:
    old = f'{key} = "{before}";'
    if text.count(old) != 1:
        raise SystemExit(f'Expected one tokenizer {key} declaration.')
    text = text.replace(old, f'{key} = "{after}";')
package.write_text(text)
PY
cp "${backup}/rust/Cargo.lock" tokenizers-cpp/Cargo.lock

cd "${root}"
preference="${version}"
if [[ "${version}" == "$(jq -r .version <<<"${current}")" ]]; then
	preference=skip
fi
nix-update --flake --system x86_64-linux --version="${preference}" \
	--override-filename pkgs/fastflowlm/package.nix fastflowlm

echo "Updated FastFlowLM to ${version} with tokenizer ${revision}." >&2
