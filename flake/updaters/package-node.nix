{
  available,
  metadata,
  scripts,
}: name: let
  package = available.${name} or null;
  updaterInfo = metadata.${name} or {};
  policy =
    if package == null
    then {}
    else package.maintenance or {};
in {
  inherit name;
  path =
    if package == null
    then null
    else builtins.unsafeDiscardStringContext package.drvPath;
  updater = scripts ? ${name};
  refresh = updaterInfo.refresh or false;
  dependencies = policy.dependencies or null;
}
