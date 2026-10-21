{
  lib,
  pkgs,
}: model:
pkgs.writeText "${lib.strings.sanitizeDerivationName model.name}.Modelfile" (
  lib.concatLines (
    ["FROM ${model.name}"]
    ++ lib.mapAttrsToList (name: value: "PARAMETER ${name} ${toString value}") model.parameters
  )
)
