import argparse
import json
import math
import sys
from dataclasses import dataclass
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener


@dataclass(frozen=True)
class OllamaProbe:
    endpoint: str
    model: str
    dimension: int
    require_acceleration: bool

    def request(self, path: str, payload: object = None) -> object:
        data = None if payload is None else json.dumps(payload).encode()
        request = Request(
            f"{self.endpoint}/{path}",
            data=data,
            headers={"Content-Type": "application/json"},
        )

        with build_opener(ProxyHandler({})).open(request, timeout=120) as response:
            return json.load(response)

    def run(self) -> None:
        response = self.request(
            "v1/embeddings",
            {"model": self.model, "input": ["Check local semantic search."]},
        )

        if not isinstance(response, dict):
            raise TypeError("Ollama returned an invalid embedding response")

        data = response.get("data")
        if not isinstance(data, list) or len(data) != 1:
            raise ValueError("Ollama must return exactly one embedding")

        item = data[0]
        if not isinstance(item, dict) or item.get("index") != 0:
            raise ValueError("Ollama returned an invalid embedding index")

        vector = item.get("embedding")
        if not isinstance(vector, list) or len(vector) != self.dimension:
            raise ValueError(
                f"Ollama must return {self.dimension} embedding dimensions"
            )

        if not all(
            type(value) in (int, float) and math.isfinite(value) for value in vector
        ) or not any(value != 0 for value in vector):
            raise ValueError("Ollama returned a non-finite or zero embedding")

        if not self.require_acceleration:
            return

        response = self.request("api/ps")
        if not isinstance(response, dict) or not isinstance(
            response.get("models"), list
        ):
            raise TypeError("Ollama returned an invalid running-model response")

        for model in response["models"]:
            if not isinstance(model, dict):
                continue

            if model.get("name") not in (self.model, f"{self.model}:latest"):
                continue

            size_vram = model.get("size_vram")
            if (
                isinstance(size_vram, (int, float))
                and not isinstance(size_vram, bool)
                and math.isfinite(size_vram)
                and size_vram > 0
            ):
                return

        raise ValueError(
            "Ollama did not report GPU use for the embedding model. "
            "Check the GPU driver, or set "
            "dotfiles.inference.ollama.requireAcceleration = false to permit CPU inference."
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--dimension", type=int, required=True)
    parser.add_argument("--require-acceleration", action="store_true")
    args = parser.parse_args()

    probe = OllamaProbe(
        args.endpoint, args.model, args.dimension, args.require_acceleration
    )

    try:
        probe.run()
    except (URLError, OSError, TypeError, ValueError) as error:
        print(f"Local embedding check failed: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
