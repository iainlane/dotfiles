{
  frontmatter = {
    description = "Turn a series of commits into a stack of pull requests, one per commit, each based on the previous one.";

    allowed-tools = [
      "Bash(gh pr create --draft *)"
      "Bash(gh pr edit *)"
      "Bash(gh pr view *)"
      "Bash(git add *)"
      "Bash(git checkout *)"
      "Bash(git commit *)"
      "Bash(git fetch *)"
      "Bash(git log *)"
      "Bash(git push *)"
      "Bash(git rebase *)"
      "Bash(git status *)"
      "Grep"
      "Read"
    ];

    argument-hint = "[--prefix=prefix] [--rebase] <from=branch point> <to=head>";
  };

  body = builtins.readFile ./instructions.md;
}
