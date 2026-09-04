{
  lib,
  pkgs,
}: let
  mkServer = {
    name,
    url,
    transport ? "http-first",
    headers ? {},
    headerEnv ? {},
    bearerAuthEnv ? null,
    envFiles ? {},
    package ? pkgs.mcp-remote,
  }: let
    headerArgs =
      lib.concatLists
      (lib.mapAttrsToList (header: value: ["--header" "${header}:${value}"]) headers);
    args = [url "--transport" transport] ++ headerArgs;
    needsWrapper = envFiles != {} || headerEnv != {} || bearerAuthEnv != null;
    command =
      if !needsWrapper
      then lib.getExe package
      else
        toString (pkgs.writeShellScript "mcp-remote-${name}" ''
          args=(
            ${lib.concatMapStringsSep "\n  " lib.escapeShellArg args}
          )

          ${lib.concatStrings (
            lib.mapAttrsToList (
              envVar: path: ''
                if ${envVar}=$(${lib.getExe' pkgs.coreutils "cat"} ${lib.escapeShellArg path}); then
                  export ${envVar}
                else
                  printf '[mcp-remote-${name}] Failed to read env var %s from %s\n' \
                    ${lib.escapeShellArg envVar} \
                    ${lib.escapeShellArg path} >&2
                  exit 1
                fi
              ''
            )
            envFiles
          )}
          ${lib.concatStrings (
            lib.mapAttrsToList (
              header: envVar: let
                shellEnv = "$" + envVar;
              in ''
                args+=(--header ${lib.escapeShellArg "${header}:"}"${shellEnv}")
              ''
            )
            headerEnv
          )}
          ${
            lib.optionalString (bearerAuthEnv != null) (let
              shellEnv = "$" + bearerAuthEnv;
            in ''
              args+=(--header ${lib.escapeShellArg "Authorization: Bearer "}"${shellEnv}")
            '')
          }

          exec ${lib.escapeShellArg (lib.getExe package)} "''${args[@]}"
        '');
  in
    {inherit command;}
    // lib.optionalAttrs (!needsWrapper) {
      inherit args;
    };
in {
  inherit mkServer;
}
