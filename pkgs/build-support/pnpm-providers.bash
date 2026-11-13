set -euo pipefail

# Local npm packages replace their registry releases through pnpm overrides of
# the form `name: file:.nix-providers/<tarball>`.
#
#   link <directory> (<tarball name> <tarball>)...
#     Links each tarball into <directory>/.nix-providers, replacing earlier
#     links there.
#   check <lockfile> (<npm name> <tarball name>)...
#     Fails unless every provider override in the lockfile, global or scoped to
#     a parent package, targets one of these packages and its current tarball,
#     and the lockfile resolves no registry release of them.

link() {
	local providers="$1/.nix-providers"
	shift

	mkdir -p "$providers"
	find "$providers" -mindepth 1 -maxdepth 1 -type l -delete

	while (($# > 0)); do
		ln -s "$2" "$providers/$1"
		shift 2
	done
}

check() {
	local lockfile="$1"
	shift

	local -A files=()
	while (($# > 0)); do
		files["$1"]="$2"
		shift 2
	done

	local target file
	while IFS=$'\t' read -r target file; do
		if [[ "${files[$target]-}" != "$file" ]]; then
			refuse
		fi
	done < <(
		sed -n '/^overrides:$/,/^$/p' "$lockfile" |
			sed -nE "s/^  ['\"]?([^'\"]+)['\"]?: file:\.nix-providers\/(.+)$/\1\t\2/p" |
			sed -E 's/^[^\t]*>//'
	)

	local key name
	while IFS= read -r key; do
		name="${key%%@*}"
		if [[ "$key" == @* ]]; then
			name="${key#@}"
			name="@${name%%@*}"
		fi
		if [[ -n "${files[$name]-}" && "${key#"$name@"}" != file:.nix-providers/* ]]; then
			refuse
		fi
	done < <(
		sed -n '/^packages:$/,/^snapshots:$/p' "$lockfile" |
			sed -nE "s/^  ['\"]?([^'\" ][^'\"]*)['\"]?:( .*)?$/\1/p"
	)
}

refuse() {
	echo "The lockfile does not install the local npm packages. Run the package's updater." >&2
	exit 1
}

command="$1"
shift

case "$command" in
link)
	link "$@"
	;;
check)
	check "$@"
	;;
*)
	printf 'Unknown command: %s\n' "$command" >&2
	exit 1
	;;
esac
