{
  fastflowlm,
  python3,
  runCommand,
  xrt,
}:
runCommand "fastflowlm-runtime-test" {
  nativeBuildInputs = [python3];
} ''
  export FLM_MODEL_PATH="$TMPDIR/models"
  python3 - <<'PY'
  import ctypes
  import json
  import os
  import subprocess
  from pathlib import Path

  package = Path('${fastflowlm}')
  runtime = Path('${xrt.xdna}')
  ctypes.CDLL(str(runtime / 'lib/libxrt_driver_xdna.so.2'), mode=os.RTLD_NOW)
  for library in Path('${fastflowlm.src}/src/lib/xrt').glob('*.so'):
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
      if not family.endswith('-rai')
      for size, model in variants.items()
      if 'aie2p' in model.get('supported_platforms', ['aie2p'])
  }
  assert actual == expected, {'actual': actual, 'expected': expected}
  PY
  touch $out
''
