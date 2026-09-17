{
  fetchFromGitHub,
  lib,
  python3,
  scowl,
  stdenvNoCC,
}: let
  # SCOWL grades its word lists by how common the words are. Size 40 is the
  # largest grade that keeps the result under 50,000 entries, and Vale loads
  # the dictionary once per process at about 0.25 microseconds an entry, so
  # below 50,000 entries the load does not show up in a run's time.
  largestSize = 40;
in
  stdenvNoCC.mkDerivation {
    pname = "prose-lint-lexicon";
    version = "0-unstable-2026-07-29";

    src = fetchFromGitHub {
      owner = "languagetool-org";
      repo = "english-pos-dict";
      rev = "52b8b63859850f27e63584036fbe857607ede6a3";
      hash = "sha256-/nEFjonnXT4yPdr9mRwjtnAV/Y6GhYAy+PB9e6y4iBQ=";
    };

    nativeBuildInputs = [python3];

    buildPhase = ''
      runHook preBuild

      python3 ${./convert.py} \
        tagger-dict/english-tagger.txt \
        ${scowl}/share/scowl \
        --largest ${toString largestSize} \
        --output english.dict

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 english.dict "$out/share/prose-lint-lexicon/english.dict"
      runHook postInstall
    '';

    doInstallCheck = true;

    installCheckPhase = ''
      runHook preInstallCheck

      dictionary="$out/share/prose-lint-lexicon/english.dict"
      entries=$(wc -l <"$dictionary")

      if [ "$entries" -gt 50000 ]; then
        echo "the lexicon has $entries entries, over the budget of 50,000" >&2
        exit 1
      fi

      if grep --quiet --extended-regexp '^that	|[^	]* [^	]*	' "$dictionary"; then
        echo "the lexicon has a 'that' entry or a multi-word entry" >&2
        exit 1
      fi

      if grep --quiet --invert-match --extended-regexp \
        '^[^	]+(	[A-Z]+\$?)+$' "$dictionary"; then
        echo "the lexicon has a line outside the word and tag format" >&2
        exit 1
      fi

      grep --quiet --line-regexp 'module	NN' "$dictionary"

      runHook postInstallCheck
    '';

    meta = {
      description = "LanguageTool's English part-of-speech dictionary in Vale's format";
      longDescription = ''
        LanguageTool's English part-of-speech dictionary, converted to the
        dictionary format that Vale reads and cut to a core of common English.
        Vale's own tagger reads a noun as a verb often enough to lose findings
        for the rules that match a part-of-speech sequence, and a dictionary
        entry with a single tag decides the reading.
      '';
      homepage = "https://github.com/languagetool-org/english-pos-dict";
      license = lib.licenses.lgpl21Only;
      platforms = lib.platforms.all;
    };
  }
