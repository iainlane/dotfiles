{inputs}: final: _: {
  inherit (inputs.cupboard.packages.${final.stdenv.hostPlatform.system}) cupboard;
}
