{
  lib,
  classes,
}: definitions: let
  fields = ["name" "includes" "_module"] ++ lib.attrNames classes;
  unwrap = value:
    if !lib.isAttrs value
    then [value]
    else if (value._type or null) == "merge"
    then lib.concatMap unwrap value.contents
    else if lib.elem (value._type or null) ["if" "override" "order"]
    then unwrap value.content
    else if (value._type or null) == "definition"
    then unwrap value.value
    else [value];
  pathFor = file: let
    segments = lib.splitString "/" file;
    positions = lib.filter (i: lib.elemAt segments i == "features") (lib.range 0 (lib.length segments - 1));
  in
    if positions == []
    then null
    else lib.drop (lib.last positions + 1) segments;
  inspect = definition: value:
    lib.mapAttrsToList (name: contribution: let
      path = pathFor definition.file;
      owned = path != null && (lib.head path == name || lib.hasPrefix "${lib.head path}-" name);
      root =
        lib.any
        (value: !lib.isAttrs value || value == {} || lib.any (field: lib.hasAttr field value) fields)
        (unwrap contribution);
      entry = path != null && path == [(lib.head path) "default.nix"];
    in {
      inherit name;
      inherit (definition) file;
      valid = owned && (!root || entry);
    })
    value;
in
  lib.filter (mention: !mention.valid)
  (lib.concatMap (definition: lib.concatMap (inspect definition) (unwrap definition.value)) definitions)
