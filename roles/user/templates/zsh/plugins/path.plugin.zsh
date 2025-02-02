typeset -U path_if_exists
path_if_exists=(
  "${HOME}/.local/bin"
  "${HOME}/.bin"
  "${HOME}/bin/ubuntu-dev-tools"
  "${HOME}/bin/ubuntu-archive-tools"
  "/opt/homebrew/opt/ruby/bin"
  "/opt/homebrew/opt/gnu-sed/libexec/gnubin"
  "${HOME}/go/bin"
  "${HOME}/.cargo/bin"
)

for ((i=${#path_if_exists}; i>=1; i--)); do
  if [ -d "${path_if_exists[$i]}" ]; then
    path=("${path_if_exists[$i]}" ${path})
  fi
done
