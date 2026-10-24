defaults=$1
settings=$2

mkdir -p -- "$(dirname -- "$settings")"
temporary=$(mktemp "$settings.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT

jq --exit-status --slurp 'length == 1 and (.[0] | type == "object")' "$defaults" >/dev/null

if [[ -e $settings || -L $settings ]]; then
	if [[ ! -f $settings ]]; then
		printf 'Plan settings must be a regular JSON file: %s\n' "$settings" >&2
		exit 1
	fi

	jq --exit-status --slurp 'length == 1 and (.[0] | type == "object")' "$settings" >/dev/null
	jq --slurp '.[0] + .[1]' "$settings" "$defaults" >"$temporary"
else
	jq . "$defaults" >"$temporary"
fi

chmod 600 "$temporary"
mv -f -- "$temporary" "$settings"
