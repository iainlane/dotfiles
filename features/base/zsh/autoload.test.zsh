setopt ERR_EXIT NO_UNSET

fpath=("$1" $fpath)
expected=(
	get-orig-source
	queue-diff
	queue-fetch
	rs
	sdeb
	sponsoring.applydebdiff
	sponsoring.applydiffgz
	sub
	unpackorig
	update-schroots
	uscan
	who-can-upload
)
actual=("$1"/*(N:t))
[[ "${(j: :)actual}" == "${(j: :)expected}" ]]

for name in "${expected[@]}"; do
	autoload -Uz "$name"
	autoload +X "$name"
done

fakeroot() { print -r -- "$*"; }
[[ $(get-orig-source) == 'debian/rules get-orig-source' ]]
