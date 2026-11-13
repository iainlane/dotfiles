# A setup hook that publishes a package's npm tarball in a `tarball` output.
# The package lists "tarball" in `outputs` and needs `npm` on PATH.
{makeSetupHook}:
makeSetupHook {name = "npm-pack-hook";} ./npm-pack-hook.sh
