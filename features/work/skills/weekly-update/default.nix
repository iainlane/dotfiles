{
  frontmatter = {
    description = "Write Linear project status updates for the projects the user worked on this week. Finds the projects with an update due, confirms which ones to cover, gathers the work of the user and their teammates from each project's issues, milestones and linked discussions, and posts one update per project after a single approval. Use when the user asks for their weekly Linear update.";

    disable-model-invocation = true;
  };

  body = builtins.readFile ./instructions.md;
}
