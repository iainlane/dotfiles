# The AgentsView skill, which tells the agents how to search the archive for
# past decisions and instructions.
#
# The package ships one copy of its skills per harness: the `claude` copy
# names Claude Code's Task tool, and the `agents` copy is generic. Each file
# starts with a header containing a hash of its body, and `agentsview skills
# list` compares that hash with the hash of the skill that it generates for the
# harness in use, so each harness has to be given the copy built for it.
{inputs, ...}: {
  dotfiles.features.agentsview.skills.homeManager = {pkgs, ...}: let
    inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) agentsview;
    skillsFor = harness: "${agentsview}/share/agentsview/skills/${harness}";
  in {
    dotfiles = {
      ai = {
        skills.agentsview.directory = skillsFor "agents";
        skillRuntimeDependencies.agentsview = ["agentsview"];
      };
      claudeCode.skills.agentsview.directory = skillsFor "claude";
    };
  };
}
