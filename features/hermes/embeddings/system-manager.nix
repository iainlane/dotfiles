# Semantic and hybrid retrieval in the LCM context engine.
# `context-engine.nix` also turns on the `/lcm` operator command wherever this
# feature is composed, because `/lcm embed warmup` and `/lcm embed backfill`
# are reachable only through that command.
{
  dotfiles.hermes.embeddings.present = true;
}
