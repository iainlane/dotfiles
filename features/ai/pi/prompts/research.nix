{models}: {
  description = "Research a technical question with web access and summarise sources";
  argument-hint = "<question>";
  model = models.sol;
  thinking = "medium";
  subagent = "researcher";
  inheritContext = false;

  body = ''
    # Research question

    Research this question and summarise the answer with links to the sources that
    you used:

    $@

    Prefer primary sources, official documentation, release notes, and source code.
    Call out uncertainty and version-specific details.
  '';
}
