# Core shell options that affect behavior

# History
setopt append_history       # Append to history instead of overwriting
setopt extended_history     # Save timestamp and duration
setopt hist_ignore_dups     # Don't save duplicate commands
setopt hist_ignore_space    # Don't save commands starting with space
setopt hist_verify         # Show command with history expansion before running it
setopt inc_append_history  # Add commands to history as they are typed
setopt share_history       # Share history between sessions

# Directory navigation
setopt auto_cd            # If command is directory name, cd to it
setopt auto_pushd        # Make cd push old directory onto stack
setopt pushd_ignore_dups # Don't push duplicate directories

# Completion
setopt auto_list         # List choices on ambiguous completion
setopt auto_menu         # Use menu completion after second tab
setopt auto_param_slash  # Add trailing slash to completed directories
setopt complete_aliases  # Complete aliases
setopt complete_in_word  # Complete from both ends of word
setopt list_types       # Show file types in completion list

# Globbing
setopt extended_glob    # Use extended globbing syntax
setopt glob_complete   # Use globbing in completion
setopt numeric_glob_sort # Sort numerically when globbing

# Input/Output
setopt correct         # Try to correct command spelling
setopt no_flow_control # Disable flow control characters
setopt interactive_comments # Allow comments in interactive shells
setopt rc_expand_param # Array expansion in parameters

# Job Control
setopt check_jobs     # Check for running jobs before exiting
setopt notify        # Report status of background jobs immediately

# Prompting
setopt prompt_subst  # Allow parameter/command substitution in prompt
