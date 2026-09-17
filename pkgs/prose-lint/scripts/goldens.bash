#!/usr/bin/env bash

# Regenerate, or compare against, the golden Vale output for every fixture.
#
#   goldens.bash <share-dir> <fixtures-dir> [--check]
#
# <share-dir> is either the installed $out/share/prose-lint or this package's
# source directory. Without --check the golden files are rewritten in place.

set -euo pipefail

if ! command -v vale >/dev/null; then

	echo "goldens.bash: vale is not on PATH" >&2
	exit 1

fi

# Vale resolves a relative StylesPath against the directory of the
# configuration file, and the configuration is written to a temporary
# directory, so both arguments are made absolute first.
share=$(cd "$1" && pwd)
fixtures=$(cd "$2" && pwd)
mode=${3:-update}

work=$(mktemp -d)

trap 'rm -rf "${work}"' EXIT

config="${work}/vale.ini"

if [[ -f "${share}/vale.ini" ]]; then

	cat "${share}/vale.ini" >"${config}"

else

	sed "s|@stylesPath@|${share}/styles|" "${share}/vale.ini.in" >"${config}"

fi

# The fixtures cover both spelling rules, and the packaged configuration leaves
# AmericanSpelling off so that only one of the pair runs at a time. Vale keeps
# the first value that it reads for a key, so this rewrites the line in place
# rather
# than appending a second [*] section.
sed -i.bak 's|^Prose.AmericanSpelling = NO$|Prose.AmericanSpelling = warning|' \
	"${config}"

status=0

for directory in "${fixtures}"/*/; do

	name=$(basename "${directory}")

	for input in "${directory}"test{valid,invalid}.*; do

		case "${input}" in
		*.golden)
			continue
			;;
		esac

		[[ -e "${input}" ]] || continue

		base=$(basename "${input}")
		stem=${base%.*}
		golden="${directory}${stem}.golden"
		actual="${work}/${name}.${stem}.actual"

		(
			cd "${directory}"
			vale \
				--no-global \
				--config "${config}" \
				--output=line \
				--filter ./filter.expr \
				"${base}" ||
				true
		) >"${actual}"

		case "${mode}" in
		--check)
			if ! diff --unified "${golden}" "${actual}"; then

				echo "fixture ${name}/${base} does not match its golden output" >&2
				status=1

			fi
			;;

		*)
			cp "${actual}" "${golden}"
			;;
		esac

	done

done

exit "${status}"
