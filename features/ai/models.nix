let
  anthropic.opus = "claude-opus-5-5";
  google.geminiPro = "Gemini 3.1 Pro (High)";
  openai = {
    astra = "gpt-6-astra";
    sol = "gpt-6.1-sol";
  };
  openrouter.sol = "~openai/gpt-sol-latest";
in {
  inherit anthropic google openai openrouter;

  defaults = {
    anthropic = anthropic.opus;
    google = google.geminiPro;
    openai = openai.astra;
  };
}
