# The locally packaged OSD frontend (pkgs/voxtype-osd-gtk4) has to match the
# daemon's version: the daemon's `voxtype-osd` launcher and the frontend
# communicate over a socket whose protocol is not stable across versions.
# Build the daemon and frontend from the same local source version on every
# channel so a single frontend version serves all Linux hosts.
_: final: _prev: {
  voxtype-onnx = final.voxtype.override {onnxSupport = true;};
}
