#!/usr/bin/env bash
set -euo pipefail

workflow=$1
case "${workflow}" in
flake-update)
	title='chore(flake): update inputs'
	intro="Automated relock of the flake inputs from the scheduled \`flake-update\` workflow (\`nix flake update\`)."
	;;
package-update)
	title='chore(pkgs): update packages'
	intro="Automated package bumps from the scheduled \`package-update\` workflow."
	;;
*)
	printf 'Unknown update workflow: %s\n' "${workflow}" >&2
	exit 2
	;;
esac

if git diff --cached --quiet; then
	echo 'No changes to propose.'
	exit 0
fi

report="${RUNNER_TEMP}/update-report.md"
body="${RUNNER_TEMP}/body.md"
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}"
if [[ "${workflow}" == flake-update ]]; then
	summary="$("${RUNNER_TEMP}/flake-lock-summary/bin/flake-lock-summary" <(git show HEAD:flake.lock) flake.lock)"
fi

{
	printf '%s\n\n' "${intro}"
	{
		if [[ "${workflow}" == flake-update ]]; then
			printf 'Updated inputs:\n\n%s\n\n' "${summary}"
		fi
		awk '!/^  > /' "${report}"
	} | LC_ALL=C awk '
    omitted || bytes + length($0) + 1 > 8192 { omitted = 1; next }
    { print; bytes += length($0) + 1 }
    END { if (omitted) print "\nThe summary was shortened." }
  '
	printf '\n[Full update report](%s).\n\n' "${run_url}"
	echo "After merging, the \`cupboard\` workflow attempts to build the requested deploy-profile outputs on main and publishes selected outputs and intermediates built during that run to the default cache."
} >"${body}"

gh auth setup-git
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

branch="${workflow}/$(date -u +%Y-%m-%d)-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
ref="refs/heads/${branch}"
git switch -c "${branch}"
git commit -m "${title}"
commit=$(git rev-parse HEAD)

cleanup() {
	local status=$? remote pr
	if remote=$(git ls-remote --heads origin "${ref}") &&
		[[ "${remote}" == "${commit}"$'\t'"${ref}" ]]; then
		if ! pr=$(gh pr list --state open --head "${branch}" --json number --jq '.[].number'); then
			echo "::warning::Could not check whether ${branch} has a pull request. Kept the branch." >&2
		elif [[ -z "${pr}" ]] && ! git push --force-with-lease="${ref}:${commit}" origin ":${ref}"; then
			echo "::warning::Could not delete ${branch} after publication failed." >&2
		fi
	fi
	exit "${status}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git push --force-with-lease="${ref}:" origin "${commit}:${ref}"
gh pr create --base main --head "${branch}" --title "${title}" --label dependencies --body-file "${body}"
trap - EXIT INT TERM

export workflow branch
gh pr list --state open --limit 1000 --json number,headRefName \
	--jq '.[] | select(.headRefName | startswith(env.workflow + "/")) | select(.headRefName != env.branch) | .number' |
	while read -r number; do
		gh pr close "${number}" --delete-branch
	done

git ls-remote --heads origin "refs/heads/${workflow}/*" |
	while read -r stale_commit stale_ref; do
		[[ "${stale_ref}" == "${ref}" ]] && continue
		git push --force-with-lease="${stale_ref}:${stale_commit}" origin ":${stale_ref}"
	done
