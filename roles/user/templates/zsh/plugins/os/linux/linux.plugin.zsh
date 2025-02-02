alias ls="ls --classify"
alias rm="rm -v --one-file-system"

export LESSOPEN="| lesspipe %s"
export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock
