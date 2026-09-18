# To update: nix run .#update-pi-web-access
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-web-access";
  source = ./source.json;
  npmRoot = ./npm-deps;
  gitHub = {
    owner = "nicobailon";
    repo = "pi-web-access";
  };
  description = "Web search, URL fetching, GitHub repo cloning, PDF extraction, YouTube video understanding, and local video analysis for Pi coding agent. Supports OpenAI, Brave, Parallel, TinyFish, Search1API, Searchinfinity, Querit, Tavily, Firecrawl, Jina, SERPdive, Kagi, Ollama, AnySearch, Bright Data SERP, SerpBase, SearXNG, Exa, Perplexity, Gemini, and Kimi.";
}
