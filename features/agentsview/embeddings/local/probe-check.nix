{pkgs, ...}: {
  ollama-embedding-probe =
    pkgs.runCommandLocal "ollama-embedding-probe" {
      nativeBuildInputs = [pkgs.python3 pkgs.ruff pkgs.pyright];
    } ''
      cp ${./check.py} check.py
      cp ${./test_check.py} test_check.py
      ruff check check.py test_check.py
      ruff format --check check.py test_check.py
      pyright --pythonversion ${pkgs.python3.pythonVersion} check.py test_check.py
      python3 -m unittest -v
      touch $out
    '';
}
