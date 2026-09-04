# The model each provider's tools default to. The harnesses under this
# directory, the Hermes feature and the prompt-conformance suite all read this
# table, so a change here reaches every one of them.
{
  anthropic = "claude-fable-5-1";
  google = "Gemini 3.1 Pro (High)";
  openai = "gpt-6-astra";
}
