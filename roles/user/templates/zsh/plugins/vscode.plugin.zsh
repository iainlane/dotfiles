CODE="code"

if [[ "${TERM_PROGRAM_VERSION}" == "*insider" ]]; then
  CODE="code-insiders"
fi

if [[ "${TERM_PROGRAM}" == "vscode" ]]; then
  . "$(${CODE} --locate-shell-integration-path zsh)"
fi
