setopt ERR_EXIT NO_UNSET PIPE_FAIL

export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
export MISE_SYSTEM_CONFIG_FILE="$HOME/system.toml"
export MISE_TEST_VERSIONS_FILE="$HOME/versions"
export MISE_TEST_INSTALL_LOG="$HOME/installs.log"
export MISE_YES=1
export MISE_CHECK_NEW_VERSIONS=0
export MISE_TOOL_UPDATE_GLOBAL_AUTO=0

mkdir -p "$HOME/work" "$HOME/profile/bin" "$HOME/dev-shell/bin"
cd "$HOME/work"
printf '1.0.0\n2.0.0\n' > "$MISE_TEST_VERSIONS_FILE"
: > "$MISE_TEST_INSTALL_LOG"

cat > "$MISE_SYSTEM_CONFIG_FILE" <<'TOML'
[tool_alias]
node = { backend = "asdf:node", versions = { lts = "2.0.0" } }
go = "asdf:go"
python = "asdf:python"
TOML

for tool in node go python; do
  plugin="$XDG_DATA_HOME/mise/plugins/$tool"
  mkdir -p "$plugin/bin"
  printf '#!/usr/bin/env bash\necho profile\n' > "$HOME/profile/bin/$tool"
  printf '#!/usr/bin/env bash\necho dev-shell\n' > "$HOME/dev-shell/bin/$tool"

  cat > "$plugin/bin/list-all" <<'BASH'
#!/usr/bin/env bash
cat "$MISE_TEST_VERSIONS_FILE"
BASH
  cat > "$plugin/bin/install" <<BASH
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "\$ASDF_INSTALL_PATH/bin"
printf '#!/usr/bin/env bash\necho %s\n' '$tool:'"\$ASDF_INSTALL_VERSION" > "\$ASDF_INSTALL_PATH/bin/$tool"
chmod +x "\$ASDF_INSTALL_PATH/bin/$tool"
printf '%s:%s\n' '$tool' "\$ASDF_INSTALL_VERSION" >> "\$MISE_TEST_INSTALL_LOG"
BASH
  cat > "$plugin/bin/list-legacy-filenames" <<BASH
#!/usr/bin/env bash
echo .$tool-version
BASH
  [[ $tool != node ]] || printf '#!/usr/bin/env bash\necho .nvmrc\n' > "$plugin/bin/list-legacy-filenames"
  cat > "$plugin/bin/parse-legacy-file" <<'BASH'
#!/usr/bin/env bash
cat "$1"
BASH
  chmod +x "$plugin/bin/"* "$HOME/profile/bin/$tool" "$HOME/dev-shell/bin/$tool"
done

export PATH="$HOME/profile/bin:$PATH"

expect() {
  if [[ $1 != $2 ]]; then
    print -u2 -r -- "Expected: $1"
    print -u2 -r -- "Actual:   $2"
    return 1
  fi
}

eval "$("$MISE_TEST_MISE" activate zsh)"
expect 'node:2.0.0 go:2.0.0 python:2.0.0' "$(node) $(go) $(python)"
for format in toml tool-versions node go python; do
  project="$HOME/work/$format"
  mkdir -p "$project"
  case $format in
    toml) printf '[tools]\nnode = "3.0.0"\n' > "$project/mise.toml"
          "$MISE_TEST_MISE" trust "$project/mise.toml" ;;
    tool-versions) printf 'node 4.0.0\n' > "$project/.tool-versions" ;;
    node) printf '5.0.0\n' > "$project/.nvmrc" ;;
    go) printf '5.0.0\n' > "$project/.go-version" ;;
    python) printf '5.0.0\n' > "$project/.python-version" ;;
  esac
  cd "$project"
  case $format in
    toml) expected='node:3.0.0' ;;
    tool-versions) expected='node:4.0.0' ;;
    *) expected="$format:5.0.0" ;;
  esac
  expect "$expected" "$(tail -1 "$MISE_TEST_INSTALL_LOG")"
  _mise_hook_precmd
  case $format in
    go|python) expect "$expected" "$("$format")" ;;
    *) expect "$expected" "$(node)" ;;
  esac
  cd "$HOME/work"
done

installed="$(<"$MISE_TEST_INSTALL_LOG")"
cd "$HOME/work/toml"
expect "$installed" "$(<"$MISE_TEST_INSTALL_LOG")"
cd "$HOME/work"

project="$HOME/work/dev-shell"
mkdir -p "$project"
printf 'PATH_add %s\n' "$HOME/dev-shell/bin" > "$project/.envrc"
printf '3.0.0\n' > "$project/.nvmrc"
"$MISE_TEST_DIRENV" allow "$project"
eval "$("$MISE_TEST_DIRENV" hook zsh)"
cd "$project"
expect dev-shell "$(node)"
_mise_hook_precmd
_mise_hook_precmd
expect dev-shell "$(node)"
cd "$HOME/work"
_mise_hook_precmd
expect node:2.0.0 "$(node)"

printf '1.0.0\n2.0.0\n6.0.0\n' > "$MISE_TEST_VERSIONS_FILE"
"$MISE_TEST_MISE" cache clear
export MISE_TOOL_UPDATE_GLOBAL_AUTO=1
"$MISE_TEST_MISE" exec -- go > "$HOME/upgraded"
expect go:6.0.0 "$(<"$HOME/upgraded")"
"$MISE_TEST_MISE" exec -- node > "$HOME/lts"
expect node:2.0.0 "$(<"$HOME/lts")"
cd "$HOME/work/toml"
"$MISE_TEST_MISE" exec -- node > "$HOME/pinned"
expect node:3.0.0 "$(<"$HOME/pinned")"
expect '[tools]
node = "3.0.0"' "$(<"$HOME/work/toml/mise.toml")"
cd "$HOME/work"
expect latest "$("$MISE_TEST_MISE" config get tools.go)"
