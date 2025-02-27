# Homebrew
if (( $+commands[brew] )); then
  eval "$(brew shellenv)"
fi

# Virtualenv configuration
export WORKON_HOME=$HOME/.virtualenvs
export VIRTUALENVWRAPPER_PYTHON=/opt/homebrew/bin/python3
export VIRTUALENVWRAPPER_VIRTUALENV=/opt/homebrew/bin/virtualenv

function virtualenvwrapper_init() {
  unfunction virtualenvwrapper_init
  source /opt/homebrew/bin/virtualenvwrapper.sh
}

alias workon='virtualenvwrapper_init && workon'
alias mkvirtualenv='virtualenvwrapper_init && mkvirtualenv'

# Less configuration
export LESSOPEN="|/opt/homebrew/bin/lesspipe.sh %s" 
export LESS_ADVANCED_PREPROCESSOR=1 

# macOS specific aliases
alias ls="ls -FG"
