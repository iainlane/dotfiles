# shellcheck shell=bash

# Packs the package in the working directory into `$tarball/package.tgz`.
# It runs from postInstall, before fixupPhase rewrites interpreters to store
# paths, so the tarball has the same contents on every system. An install phase
# that needs the tarball earlier can call it first.
npmPackHook() {
	local destination="${tarball:?npmPackHook needs a tarball output}"

	if [[ -e "$destination/package.tgz" ]]; then
		return
	fi

	echo "Executing npmPackHook"

	mkdir -p "$destination"
	npm_config_cache="$TMPDIR/npm-pack-cache" \
		npm pack --ignore-scripts --loglevel=warn --pack-destination "$destination" >/dev/null

	local packed=("$destination"/*.tgz)
	mv "${packed[0]}" "$destination/package.tgz"

	echo "Finished npmPackHook"
}

postInstallHooks+=(npmPackHook)
