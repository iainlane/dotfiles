let
  anthropic.fable = "claude-fable-5-1";
  google.geminiPro = "Gemini 3.1 Pro (High)";
  openai = {
    astra = "gpt-6-astra";
    sol = "gpt-6-sol";
  };
  openrouter.sol = "~openai/gpt-sol-latest";
in {
  inherit anthropic google openai openrouter;

  defaults = {
    anthropic = anthropic.fable;
    google = google.geminiPro;
    openai = openai.astra;
  };
}
