{lib}: {
  errors = {
    name,
    package,
    packages,
    inputs,
  }: let
    policy = package.maintenance or {};
    source = policy.source or null;
    script = package.updateScript or null;
    declaredInputs = policy.inputs or [];
    dependencies = policy.dependencies or [];
    failures = [
      {
        valid = builtins.elem source ["input" "release" "pin" "repository" "derived"];
        message = "declare a maintenance source (input, release, pin, repository or derived)";
      }
      {
        valid = builtins.isList declaredInputs && lib.all (input: builtins.elem input inputs) declaredInputs;
        message = "maintenance inputs must refer to declared flake inputs";
      }
      {
        valid = builtins.isList dependencies && lib.all (dependency: dependency != name && builtins.elem dependency packages) dependencies;
        message = "maintenance dependencies must refer to other local packages";
      }
      {
        valid = source != "input" || declaredInputs != [];
        message = "input-following packages must specify their inputs";
      }
      {
        valid = source != "derived" || dependencies != [];
        message = "derived packages must specify their provider packages";
      }
      {
        valid = source != "pin" || (builtins.isString (policy.reason or null) && policy.reason != "");
        message = "pinned sources must include a reason";
      }
      {
        valid = !(policy.temporary or false) || (builtins.isString (policy.retirement or null) && policy.retirement != "");
        message = "temporary changes must specify a retirement condition";
      }
      {
        valid = builtins.isBool (policy.refresh or false) && (!(policy.refresh or false) || script != null);
        message = "refresh capability requires a local updater";
      }
      {
        valid = script == null || lib.isDerivation script;
        message = "local updateScript must be an executable derivation, not an inherited upstream script";
      }
    ];
  in
    map (failure: "${name}: ${failure.message}") (lib.filter (failure: !failure.valid) failures);
}
