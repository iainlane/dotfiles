# `voxtype-onnx` is the daemon with the ONNX speech-recognition backends
# built in. `pkgs/voxtype-osd-gtk4` takes its `src` and `cargoDeps` from this
# attribute. The frontend and the daemon talk over a socket whose protocol
# changes between versions, so both must be built from the same revision.
_: final: _prev: {
  voxtype-onnx = final.voxtype.override {onnxSupport = true;};
}
