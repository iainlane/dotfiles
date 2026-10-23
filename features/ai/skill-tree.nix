# Assembles a set of skills (see ./skill-type.nix) into one directory, leaving
# out any skill named in `excludes`.
#
# A `skill` value is rendered into `<name>/SKILL.md`. Codex ignores
# `disable-model-invocation` in the SKILL.md frontmatter and reads the same
# setting from `agents/openai.yaml` as `policy.allow_implicit_invocation`, so
# the tree renders that file too when the frontmatter sets
# `disable-model-invocation`.
#
# A `directory` value is a skill directory or a directory of skills.
# Evaluation cannot tell the two apart, because the contents of a store path
# are not readable until it is built, so each directory becomes a directory of
# skills in a build of its own, which looks for `SKILL.md` at the top of the
# directory. For a directory of skills the key is ignored: the Agent Skills
# format requires a skill's `name` to match its directory name.
#
# `buildEnv` then merges the skills, and aborts the build when two skills with
# one name differ.
{
  lib,
  pkgs,
}: let
  toYAML = lib.generators.toYAML {};

  renderFrontmatter = frontmatter:
    lib.concatStrings (lib.mapAttrsToList (key: value: "${key}: ${toYAML value}\n") frontmatter);

  # Codex skips a skill whose SKILL.md is a symlink, so the rendered files are
  # copied into the skill's directory.
  renderSkill = name: {
    frontmatter,
    body,
  }: let
    files =
      {
        "SKILL.md" = pkgs.writeText "SKILL.md" ''
          ---
          ${renderFrontmatter (frontmatter // {inherit name;})}---

          ${body}'';
      }
      // lib.optionalAttrs frontmatter.disable-model-invocation {
        "agents/openai.yaml" = pkgs.writeText "openai.yaml" ''
          ${toYAML {policy.allow_implicit_invocation = false;}}
        '';
      };
  in
    pkgs.runCommandLocal "skills-${name}" {} (lib.concatStrings (lib.mapAttrsToList (path: file: ''
        install -D --mode=0444 ${file} "$out"/${lib.escapeShellArg "${name}/${path}"}
      '')
      files));

  asSkillDirectory = name: value:
    if value ? skill
    then renderSkill name value.skill
    else
      pkgs.runCommandLocal "skills-${name}" {source = "${value.directory}";} ''
        if [ -e "$source/SKILL.md" ]; then
          mkdir "$out"
          ln -s "$source" "$out"/${lib.escapeShellArg name}
        else
          ln -s "$source" "$out"
        fi
      '';
in
  # The excluded names are checked against the merged tree, after the build,
  # because a directory of skills only reveals its names once it is built. A
  # name that matches nothing fails the build, so a stale exclusion cannot
  # linger after a skill is renamed or removed.
  {
    skills,
    excludes ? [],
  }:
    pkgs.buildEnv {
      name = "skills";
      paths = lib.mapAttrsToList asSkillDirectory skills;

      postBuild =
        lib.concatMapStringsSep "\n" (name: ''
          if [ ! -e "$out"/${lib.escapeShellArg name} ]; then
            echo "skill exclusion ${name} matches no skill in the tree" >&2
            exit 1
          fi

          rm -r "$out"/${lib.escapeShellArg name}
        '')
        excludes;
    }
