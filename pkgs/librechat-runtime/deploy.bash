# shellcheck shell=bash

deployment="${1:?Provide the deployment directory.}"
rm -rf node_modules packages/{cli,runtime,codeapi-bridge}/node_modules
CI=true pnpm install --prod --offline --frozen-lockfile --ignore-scripts

mkdir -p "$deployment/.workspace/packages"
cp -a package.json pnpm-workspace.yaml pnpm-lock.yaml node_modules "$deployment/.workspace/"

for package in cli runtime codeapi-bridge; do
	destination="$deployment/.workspace/packages/$package"
	mkdir -p "$destination"
	cp -a "packages/$package/package.json" "packages/$package/dist" "$destination/"
	if [[ -d "packages/$package/node_modules" ]]; then
		cp -a "packages/$package/node_modules" "$destination/"
	fi
done

for entry in package.json dist node_modules; do
	ln -s ".workspace/packages/cli/$entry" "$deployment/$entry"
done

find "$deployment" -type f \( -name .modules.yaml -o -name .pnpm-workspace-state-v1.json \) -delete
find "$deployment" -type d -name .bin -prune -exec rm -r {} +
