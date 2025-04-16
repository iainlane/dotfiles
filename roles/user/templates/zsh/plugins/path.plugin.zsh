typeset -U path_if_exists
path_if_exists=(
  "${HOME}/.local/bin"
  "${HOME}/.local/pipx/bin"
  "${HOME}/bin/ubuntu-dev-tools"
  "${HOME}/bin/ubuntu-archive-tools"
  "/opt/homebrew/opt/ruby/bin"
  "/opt/homebrew/opt/gnu-sed/libexec/gnubin"
  "/opt/homebrew/opt/grep/libexec/gnubin"
  "${HOME}/go/bin"
  "${HOME}/.cargo/bin"
  "/snap/bin"
)

for ((i=${#path_if_exists}; i>=1; i--)); do
  if [ -d "${path_if_exists[$i]}" ]; then
    path=("${path_if_exists[$i]}" ${path})
  fi
done
