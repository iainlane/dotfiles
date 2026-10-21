{
  lib,
  stdenv,
  fetchFromGitHub,
  callPackage,
  updaters,
  gh,
  nix-update,
  python3,
  cmake,
  pkg-config,
  gitMinimal,
  curl,
  boost,
  libdrm,
  systemd,
  ocl-icd,
  opencl-headers,
  libuuid,
  libxml2,
  ncurses,
  yaml-cpp,
  openssl,
  rapidjson,
  protobuf,
  libsystemtap,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "xrt";
  version = "2.21.75";

  __structuredAttrs = true;
  strictDeps = true;

  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "XRT";
    tag = finalAttrs.version;
    fetchSubmodules = true;
    hash = "sha256-sujiSRZuIelhvUew7yeCfApAmp/Pf2+F38KO9cxI2HE=";
  };

  # The CMake scripts read the distribution from /etc/os-release, which the
  # build sandbox does not have. The aiebu `asm` and `dump` utilities link
  # statically against glibc, and the aiebu tests use them.
  postPatch = ''
    printf 'ID=nixos\nVERSION_ID="${lib.trivial.release}"\n' > os-release
    substituteInPlace $(grep -rl /etc/os-release --include='*.cmake' .) \
      --replace-fail /etc/os-release "$PWD/os-release"

    substituteInPlace src/runtime_src/core/common/aiebu/src/cpp/utils/CMakeLists.txt \
      --replace-fail "add_subdirectory(asm)" "" \
      --replace-fail "add_subdirectory(dump)" ""

    substituteInPlace src/runtime_src/core/common/aiebu/CMakeLists.txt \
      --replace-fail "add_subdirectory(test)" ""

    substituteInPlace src/CMake/icd.cmake \
      --replace-fail '"/etc/OpenCL/vendors"' '"etc/OpenCL/vendors"'
  '';

  nativeBuildInputs = [
    cmake
    pkg-config
    gitMinimal
  ];

  buildInputs = [
    boost
    curl
    libdrm
    systemd
    ocl-icd
    opencl-headers
    libuuid
    libxml2
    ncurses
    yaml-cpp
    openssl
    rapidjson
    protobuf
    libsystemtap
  ];

  cmakeDir = "../src";

  env.LDFLAGS = "-Wl,--copy-dt-needed-entries";

  cmakeFlags = [
    (lib.cmakeBool "XRT_NATIVE_BUILD" true)
    (lib.cmakeBool "XRT_NPU" true)
    (lib.cmakeBool "XRT_SKIP_SUBMODULE_UPDATE" true)
    (lib.cmakeFeature "XRT_BUILD_NUMBER" (lib.versions.patch finalAttrs.version))
    (lib.cmakeFeature "CMAKE_CXX_STANDARD" "20")
    (lib.cmakeFeature "CMAKE_INSTALL_BINDIR" "bin")
    (lib.cmakeFeature "CMAKE_INSTALL_LIBDIR" "lib")
    (lib.cmakeFeature "CMAKE_INSTALL_INCLUDEDIR" "include")
  ];

  passthru = {
    xdna = callPackage ./xdna.nix {xrt = finalAttrs.finalPackage;};
    updateScript = updaters.mkScriptUpdater {
      pname = "xrt";
      script = ./update.sh;
      extraRuntimeInputs = [gh nix-update];
    };
    tests.updater = updaters.mkScriptUpdaterTest {
      pname = "xrt";
      script = ./update.sh;
      test = ./update.test.sh;
      extraInputs = [python3];
    };
  };

  meta = {
    description = "Xilinx Runtime for AMD XDNA NPU devices";
    homepage = "https://github.com/Xilinx/XRT";
    license = lib.licenses.asl20;
    platforms = ["x86_64-linux"];
  };
})
