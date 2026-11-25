{shard}: targets: let
  inherit (builtins) attrNames concatStringsSep elemAt genList groupBy length listToAttrs match substring;

  hasPrefix = prefix: text: substring 0 (builtins.stringLength prefix) text == prefix;

  shardFor = target:
    if target.system != "x86_64-linux"
    then "system-${target.system}"
    else if target.cohort == "x86_64-linux-deploy"
    then "x86_64-linux-deploy"
    else if target.rootSuffix == "x86_64-linux/packages"
    then "x86_64-linux-packages"
    else if hasPrefix "x86_64-linux/slow-checks-podman-oci-containers-" target.rootSuffix
    then "x86_64-linux-podman-oci"
    else if hasPrefix "x86_64-linux/slow-checks-podman-podman" target.rootSuffix
    then "x86_64-linux-podman"
    else if hasPrefix "x86_64-linux/slow-checks-" target.rootSuffix
    then "x86_64-linux-other-slow"
    else "x86_64-linux-checks";

  groups = groupBy shardFor targets;
  checks = groups.x86_64-linux-checks or [];
  chunkSize = 48;
  checkShards = genList (index: let
    offset = index * chunkSize;
    remaining = length checks - offset;
  in {
    name = "x86_64-linux-checks-${toString offset}";
    value = genList (i: elemAt checks (offset + i)) (
      if remaining < chunkSize
      then remaining
      else chunkSize
    );
  }) (builtins.div (length checks + chunkSize - 1) chunkSize);

  shards = removeAttrs groups ["x86_64-linux-checks"] // listToAttrs checkShards;

  field = pattern: value:
    if match pattern value == null
    then throw "Invalid evaluation manifest field: ${value}"
    else value;

  rows = includePaths: name:
    concatStringsSep "" (map (target: let
      suffix = field "[^\t\n\r]+" target.rootSuffix;
      path = field "[^\t\n\r]+\\.drv" target.rootDrvPath;
    in
      "${name}\t${suffix}"
      + (
        if includePaths
        then "\t${path}"
        else ""
      )
      + "\n")
    shards.${name});
in
  if shard == null
  then concatStringsSep "" (map (rows false) (attrNames shards))
  else rows true shard
