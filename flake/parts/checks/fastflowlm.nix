{lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks =
      lib.genAttrs ["xrt-updater" "fastflowlm-updater"] (name: let
        package = lib.removeSuffix "-updater" name;
        directory = ../../../pkgs + "/${package}";
      in
        pkgs.runCommandLocal "${name}-test" {
          nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.python3 pkgs.diffutils];
        } ''
          bash ${directory}/update.test.sh ${directory}/update.sh
          touch $out
        '')
      // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
        fastflowlm =
          pkgs.runCommand "fastflowlm-runtime-test" {
            nativeBuildInputs = [pkgs.python3];
          } ''
            export FLM_MODEL_PATH="$TMPDIR/models"
            python3 - <<'PY'
            import ctypes
            import json
            import os
            import subprocess
            from pathlib import Path

            package = Path('${pkgs.fastflowlm}')
            runtime = Path('${pkgs.xrt.xdna}')
            ctypes.CDLL(str(runtime / 'lib/libxrt_driver_xdna.so.2'), mode=os.RTLD_NOW)
            for library in Path('${pkgs.fastflowlm.src}/src/lib/xrt').glob('*.so'):
                assert (package / 'lib' / library.name).is_file()

            # NPU engines require symbols exported by flm.
            result = subprocess.run(
                [str(package / 'bin/flm'), 'list', '--json'],
                check=True, capture_output=True, text=True,
                env=os.environ | {'LD_BIND_NOW': '1'},
            )
            actual = {
                model['name']: model['installed']
                for model in json.loads(result.stdout)['models']
            }
            catalog = json.loads((package / 'share/flm/model_list.json').read_text())
            expected = {
                f'{family}:{size}': False
                for family, variants in catalog['models'].items()
                for size in variants
            }
            assert actual == expected
            PY
            touch $out
          '';
      };
  };
}
