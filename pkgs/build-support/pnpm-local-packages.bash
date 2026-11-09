# shellcheck shell=bash

# Usage: pnpm-local-packages.bash PROVIDED
#
# PROVIDED is a JSON file listing the local npm packages to install, each with
# its npm `name` and `tarball`. Run from the directory that contains
# pnpm's `node_modules`, after `pnpm install`.
#
# pnpm installs every package into its virtual store, at
# `node_modules/.pnpm/<name>@<version>.../node_modules/<name>`, and links the
# package's dependencies beside it. Replacing the directory's contents with the
# local tarball changes the copy that every dependant uses. The lockfile must
# resolve the local version and install the local package's dependencies,
# which the package's updater records as `packageExtensions`.

set -euo pipefail

provided="$1"
store=node_modules/.pnpm

if [[ ! -d "${store}" ]]; then
	exit 0
fi

while IFS=$'\t' read -r name tarball; do
	# pnpm writes a scoped name's `/` as `+` in virtual store entries.
	entry="${name//\//+}"
	manifest="$(tar -xzOf "${tarball}" package/package.json)"
	version="$(jq -r .version <<<"${manifest}")"
	dependencies="$(jq -r '.dependencies // {} | keys[]' <<<"${manifest}")"

	for directory in "${store}/${entry}@"*"/node_modules/${name}"; do
		if [[ ! -d "${directory}" ]]; then
			continue
		fi

		installed="$(jq -r .version "${directory}/package.json")"
		if [[ "${installed}" != "${version}" ]]; then
			echo "pnpm-lock.yaml resolves ${name} to ${installed}, but the local package is ${version}. Run the package's updater." >&2
			exit 1
		fi

		modules="${directory%/"${name}"}"
		while IFS= read -r dependency; do
			if [[ -n "${dependency}" && ! -e "${modules}/${dependency}" ]]; then
				echo "pnpm-lock.yaml does not install ${dependency} for the local ${name} ${version}. Run the package's updater." >&2
				exit 1
			fi
		done <<<"${dependencies}"

		chmod -R u+w "${directory}"
		rm -rf "${directory}"
		mkdir "${directory}"
		tar -xzf "${tarball}" --strip-components=1 -C "${directory}"
		chmod -R u+w "${directory}"
	done
done < <(jq -r '.[] | [.name, .tarball] | @tsv' "${provided}")
