zstyle ':antidote:bundle' use-friendly-names 'yes'
zstyle ':antidote:bundle:*' zcompile 'yes'
zstyle ':antidote:static' zcompile 'yes'
zstyle ':antidote:plugin:*' defer-options '-p'

# disable sort when completing `git checkout`
zstyle ':completion:*:git-checkout:*' sort false
