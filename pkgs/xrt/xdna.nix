# XRT loads the plugin at run time from a path relative to the directory that
# contains `libxrt_coreutil.so`, so both have to be installed under one prefix.
{
  lib,
  stdenv,
  fetchFromGitHub,
  symlinkJoin,
  cmake,
  pkg-config,
  git,
  python3,
  gawk,
  xrt,
  boost,
  libdrm,
  libuuid,
  libelf,
  ocl-icd,
  opencl-headers,
  ncurses,
  libxml2,
  yaml-cpp,
  openssl,
  rapidjson,
  protobuf,
  systemd,
  libsystemtap,
}: let
  plugin = stdenv.mkDerivation {
    pname = "xrt-amdxdna-plugin";
    inherit (xrt) version;

    __structuredAttrs = true;
    strictDeps = true;

    src = fetchFromGitHub {
      owner = "amd";
      repo = "xdna-driver";
      tag = xrt.version;
      fetchSubmodules = true;
      hash = "sha256-bBiI42bwap6O59MQdIylX7uz+fLUF75RTyNWTJfAFds=";
    };

    nativeBuildInputs = [
      cmake
      pkg-config
      git
      python3
      gawk
    ];

    buildInputs = [
      xrt
      boost
      libdrm
      libuuid
      libelf
      ocl-icd
      opencl-headers
      ncurses
      libxml2
      yaml-cpp
      openssl
      rapidjson
      protobuf
      systemd
      libsystemtap
    ];

    env.LDFLAGS = "-Wl,--copy-dt-needed-entries";

    # The CMake scripts read the distribution from /etc/os-release, which the
    # build sandbox does not have.
    postPatch = ''
      printf 'ID=nixos\nVERSION_ID="${lib.trivial.release}"\n' > os-release
      substituteInPlace $(grep -rl /etc/os-release --include='*.cmake' .) \
        --replace-fail /etc/os-release "$PWD/os-release"

      substituteInPlace CMakeLists.txt \
        --replace-fail 'set(XDNA_BIN_DIR      /bins)' 'set(XDNA_BIN_DIR      bins)'
    '';

    cmakeFlags = [
      (lib.cmakeBool "SKIP_KMOD" true)
      (lib.cmakeFeature "XRT_BUILD_NUMBER" (lib.versions.patch xrt.version))
      (lib.cmakeFeature "CMAKE_CXX_STANDARD" "17")
      (lib.cmakeFeature "CMAKE_INSTALL_LIBDIR" "lib")
      (lib.cmakeFeature "CMAKE_INSTALL_BINDIR" "bin")
      (lib.cmakeFeature "CMAKE_INSTALL_INCLUDEDIR" "include")
    ];

    postInstall = ''
      cp -a "$out/bins/lib/." "$out/lib/"
      rm -r "$out/bins"
    '';

    meta = {
      description = "AMD XDNA shim plugin for XRT";
      homepage = "https://github.com/amd/xdna-driver";
      license = lib.licenses.asl20;
      platforms = ["x86_64-linux"];
    };
  };
in
  symlinkJoin {
    name = "xrt-amdxdna-${xrt.version}";
    paths = [
      plugin
      xrt
    ];

    passthru = {inherit plugin;};

    meta = {
      description = "Xilinx Runtime with AMD XDNA NPU support";
      homepage = "https://github.com/amd/xdna-driver";
      license = lib.licenses.asl20;
      platforms = ["x86_64-linux"];
    };
  }
