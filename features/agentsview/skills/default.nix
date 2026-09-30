# The AgentsView skill, which tells the agents how to search the archive for
# past decisions and instructions.
#
# The package ships one copy of its skills per harness: the `claude` copy
# names Claude Code's Task tool, and the `agents` copy is generic. Each file
# starts with a header containing a hash of its body, and `agentsview skills
# list` compares that hash with the hash of the skill that it generates for the
# harness in use, so each harness has to be given the copy built for it.
{
  flake.features.agentsview.provides.skills.homeManager = {
    inputs,
    system,
    ...
  }: let
    skillsFor = harness: "${inputs.llm-agents.packages.${system}.agentsview}/share/agentsview/skills/${harness}";
  in {
    dotfiles.ai.skills.agentsview = skillsFor "agents";
    dotfiles.claudeCode.skills.agentsview = skillsFor "claude";
  };
}
