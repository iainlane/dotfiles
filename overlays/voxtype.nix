# The locally packaged OSD frontend (pkgs/voxtype-osd-gtk4) has to match the
# daemon's version: the daemon's `voxtype-osd` launcher and the frontend
# communicate over a socket whose protocol is not stable across versions.
# Take the daemon from the unstable input on every channel so a single
# frontend version serves all hosts.
{inputs}: final: _prev: {
  inherit
    ((import inputs.nixpkgs {
      inherit (final.stdenv.hostPlatform) system;
    }))
    voxtype-onnx
    ;
}
