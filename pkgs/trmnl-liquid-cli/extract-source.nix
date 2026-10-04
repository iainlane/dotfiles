{
  runCommand,
  dwarfs,
}: image:
runCommand "trmnl-liquid-cli-released-source" {
  nativeBuildInputs = [dwarfs];
} ''
  mkdir unpacked
  dwarfsextract -i ${image} -o unpacked
  mkdir -p "$out/library"
  cp unpacked/local/{trmnl-liquid-cli.rb,Gemfile,Gemfile.lock} "$out/"
  version=$(sed -n 's/^    trmnl-liquid (\([^)]*\))$/\1/p' "$out/Gemfile.lock")
  test -n "$version"
  set -- unpacked/lib/ruby/gems/*/gems/"trmnl-liquid-$version"
  test "$#" = 1
  cp -r "$1/". "$out/library/"
''
