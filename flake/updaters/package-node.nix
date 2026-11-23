{
  available,
  localPackages,
  metadata,
  scripts,
}: name: let
  updaterInfo = metadata.${name} or {};
  policy = localPackages.${name}.maintenance or {};
  refresh = updaterInfo.refresh or false;
in {
  inherit name refresh;
  path =
    if available ? ${name}
    then builtins.unsafeDiscardStringContext available.${name}.drvPath
    else null;
  updater = scripts ? ${name};
  inputs =
    if refresh && !(policy ? refreshInputs)
    then null
    else
      (policy.inputs or [])
      ++ (
        if refresh
        then policy.refreshInputs
        else []
      );
  dependencies = policy.dependencies or null;
}
