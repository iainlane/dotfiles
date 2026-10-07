import io
import json
import unittest
from unittest.mock import patch

from check import OllamaProbe


class OllamaProbeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.probe = OllamaProbe("http://127.0.0.1:11434", "baai/bge-m3", 3, True)

    def test_accelerated_embedding(self) -> None:
        for name in ("baai/bge-m3", "baai/bge-m3:latest"):
            with self.subTest(name=name), patch("check.build_opener") as opener:
                opener.return_value.open.side_effect = [
                    io.BytesIO(
                        json.dumps(
                            {"data": [{"index": 0, "embedding": [1, 2, 3]}]}
                        ).encode()
                    ),
                    io.BytesIO(
                        json.dumps(
                            {"models": [{"name": name, "size_vram": 1024}]}
                        ).encode()
                    ),
                ]

                self.probe.run()

                requests = [
                    call.args[0] for call in opener.return_value.open.call_args_list
                ]
                self.assertEqual(
                    [
                        (
                            "http://127.0.0.1:11434/v1/embeddings",
                            {
                                "model": "baai/bge-m3",
                                "input": ["Check local semantic search."],
                            },
                        ),
                        ("http://127.0.0.1:11434/api/ps", None),
                    ],
                    [
                        (
                            request.full_url,
                            json.loads(request.data) if request.data else None,
                        )
                        for request in requests
                    ],
                )

    def test_invalid_embeddings(self) -> None:
        responses = [
            None,
            {},
            {"data": []},
            {"data": [{"index": 1, "embedding": [1, 2, 3]}]},
            {"data": [{"index": 0, "embedding": [1, 2]}]},
            *(
                {"data": [{"index": 0, "embedding": vector}]}
                for vector in (
                    [0, 0, 0],
                    [1, None, 3],
                    [1, True, 3],
                    [1, float("nan"), 3],
                    [1, float("inf"), 3],
                )
            ),
        ]

        for response in responses:
            with self.subTest(response=response), patch("check.build_opener") as opener:
                opener.return_value.open.return_value = io.BytesIO(
                    json.dumps(response).encode()
                )

                with self.assertRaises((TypeError, ValueError)):
                    self.probe.run()

                self.assertEqual(1, opener.return_value.open.call_count)

    def test_requires_acceleration_for_the_embedding_model(self) -> None:
        responses = [
            None,
            {"models": []},
            {"models": [{"name": "baai/bge-m3:latest", "size_vram": 0}]},
            {"models": [{"name": "different-model", "size_vram": 1024}]},
        ]

        for response in responses:
            with self.subTest(response=response), patch("check.build_opener") as opener:
                opener.return_value.open.side_effect = [
                    io.BytesIO(
                        json.dumps(
                            {"data": [{"index": 0, "embedding": [1, 2, 3]}]}
                        ).encode()
                    ),
                    io.BytesIO(json.dumps(response).encode()),
                ]

                with self.assertRaises((TypeError, ValueError)):
                    self.probe.run()

    def test_cpu_opt_in(self) -> None:
        with patch("check.build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(
                json.dumps({"data": [{"index": 0, "embedding": [1, 2, 3]}]}).encode()
            )
            probe = OllamaProbe(
                self.probe.endpoint, self.probe.model, self.probe.dimension, False
            )

            probe.run()

            self.assertEqual(1, opener.return_value.open.call_count)


if __name__ == "__main__":
    unittest.main()
