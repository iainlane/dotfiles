# Pack an installed npm package directory as a tarball that npm can install.
# npm resolves the package's dependencies from the consumer's lockfile, so the
# tarball leaves out the directory's own `node_modules`.
{
  lib,
  runCommand,
}: {
  name,
  version,
  directory,
}:
runCommand "${lib.last (lib.splitString "/" name)}-${version}.tgz" {} ''
  tar -czf "$out" -C ${directory} --exclude=./node_modules --transform 's,^\.,package,' .
''
