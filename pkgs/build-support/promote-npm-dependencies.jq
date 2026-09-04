# Declare the packages in $deps as runtime dependencies of the manifest on
# stdin, at the versions $deps gives, and stop declaring them as development
# ones.
#
# Adding to `dependencies` alone is not enough. npm marks a package `dev` in
# the lockfile when only `devDependencies` requires it, and an install run
# with `--omit=dev` skips every package marked that way, even when the
# manifest also lists it under `dependencies`. Removing the development
# declaration is what clears the mark.
#
# `pi-extension.nix` and the updater in `updaters.nix` both apply this, to the
# manifest the build installs from and the manifest the updater resolves, so
# that the two agree.

.dependencies += $deps
| if has("devDependencies")
  then .devDependencies |= with_entries(select($deps[.key] == null))
  else .
  end
