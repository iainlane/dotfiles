#!/usr/bin/env python3
"""Verify immutable target identity without retaining raw diagnostics."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

SOURCE_COMMIT = "f3f125f64022b41d61f67435d30296ae8ba0f8d7"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("off", "on"), required=True)
    parser.add_argument("--original", required=True)
    parser.add_argument("--wrapper", required=True)
    parser.add_argument("--wrapper-commit", required=True)
    parser.add_argument("--prepare-commit", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    if args.timeout < 1 or any(not re.fullmatch(r"[0-9a-f]{40}", commit) or commit == "0" * 40 for commit in (args.wrapper_commit, args.prepare_commit)):
        parser.error("Use exact commits and a positive timeout")
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=False, mode=0o700)
    secrets = [value for key, value in os.environ.items() if key.startswith("IDENTITY_SECRET_") and value]
    measurements = []
    results = {
        "mode": args.mode,
        "sourceCommit": SOURCE_COMMIT,
        "wrapperCommit": args.wrapper_commit,
        "prepareCommit": args.prepare_commit,
        "workflowCommit": os.environ.get("IDENTITY_WORKFLOW_COMMIT"),
        "runId": os.environ.get("GITHUB_RUN_ID"),
        "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "runnerOs": os.environ.get("RUNNER_OS"),
        "runnerImage": os.environ.get("ImageOS"),
        "runnerImageVersion": os.environ.get("ImageVersion"),
        "configurationFetchesBeforeTiming": True,
        "sourceFetchCacheResetBetweenCommands": False,
        "storeResetBetweenCommands": False,
        "noWriteLockFile": True,
        "measurements": measurements,
        "complete": False,
    }

    def safe(value):
        encoded = canonical(value)
        if any(secret in encoded or json.dumps(secret)[1:-1] in encoded for secret in secrets):
            raise RuntimeError("Credential values are not permitted")
        if re.search(r"[A-Za-z][A-Za-z0-9+.-]*://[^/\s\"]+@", encoded):
            raise RuntimeError("URI user information is not permitted")
        return encoded

    def read_command(command):
        return subprocess.run(command, check=True, capture_output=True, timeout=args.timeout).stdout.decode().strip()

    def clean_sources():
        for source, commit in ((args.original, SOURCE_COMMIT), (args.wrapper, args.wrapper_commit)):
            if read_command(["git", "-C", source, "rev-parse", "HEAD"]) != commit or read_command(["git", "-C", source, "status", "--porcelain=v1", "--untracked-files=no"]):
                raise RuntimeError("A checkout differs from its immutable tracked source")
        helper = Path(args.wrapper).resolve() / "publication-validation/identity.py"
        if Path(__file__).resolve() != helper or read_command(["git", "-C", args.wrapper, "ls-files", "--error-unmatch", "publication-validation/identity.py"]) != "publication-validation/identity.py":
            raise RuntimeError("Use the tracked helper from the wrapper checkout")
        return hashlib.sha256(helper.read_bytes()).hexdigest()

    def measure(label, command):
        started = time.monotonic()
        with tempfile.TemporaryDirectory(prefix="cupboard-identity-time-") as temporary:
            timing_file = Path(temporary) / "time.txt"
            process = subprocess.Popen(["/usr/bin/time", "-p", "-o", str(timing_file), *command], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
            timed_out = False
            try:
                stdout, _ = process.communicate(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    stdout, _ = process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    stdout, _ = process.communicate()
            process_timing = {}
            if timing_file.exists():
                for line in timing_file.read_text().splitlines():
                    match = re.fullmatch(r"(real|user|sys) ([0-9]+(?:\.[0-9]+)?)", line)
                    if match:
                        process_timing[match[1] + "Seconds"] = float(match[2])
        receipt = {"label": label, "elapsedSeconds": time.monotonic() - started, "processTiming": process_timing, "exitCode": process.returncode, "timedOut": timed_out}
        measurements.append(receipt)
        if process.returncode != 0:
            raise RuntimeError("Identity command failed")
        value = json.loads(stdout)
        receipt["jsonSha256"] = hashlib.sha256(safe(value).encode()).hexdigest()
        print(json.dumps(receipt), flush=True)
        return value

    def lock_file(source):
        raw = (Path(source) / "flake.lock").read_bytes()
        return json.loads(raw), hashlib.sha256(raw).hexdigest()

    def without_wrapper_prefix(value):
        if isinstance(value, list):
            return value[1:] if value[:1] == ["dotfiles"] else value
        if isinstance(value, dict):
            return {key: without_wrapper_prefix(child) for key, child in value.items()}
        return value

    def store_path(value, basename=False):
        if not isinstance(value, str):
            raise RuntimeError("A store path is unavailable")
        part = value if basename else value.removeprefix("/nix/store/")
        if (not basename and part == value) or not re.fullmatch(r"[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+", part):
            raise RuntimeError("A store path is invalid")
        return "/nix/store/" + part

    def derivation_map(document, manifest):
        if not isinstance(document, dict) or set(document) != {"version", "derivations"} or type(document["version"]) is not int or document["version"] != 4 or not isinstance(document["derivations"], dict):
            raise RuntimeError("Use the version 4 derivation JSON format")
        mapped = {}
        for basename, derivation in document["derivations"].items():
            path = store_path(basename, basename=True)
            if not path.endswith(".drv") or not isinstance(derivation, dict) or type(derivation.get("version")) is not int or derivation["version"] != 4 or not isinstance(derivation.get("outputs"), dict):
                raise RuntimeError("A version 4 derivation is invalid")
            mapped[path] = derivation
        if set(mapped) != {target["rootDrvPath"] for target in manifest}:
            raise RuntimeError("The derivations differ from the manifest")
        return mapped

    def selected_output_names(target):
        return target.get("outputs", ["out"])

    def selected_outputs(manifest, derivations, query):
        if not isinstance(query, list) or len(query) != len(manifest):
            raise RuntimeError("The selected output query differs from the manifest")
        selected = []
        for target, result in zip(manifest, query, strict=True):
            if not isinstance(result, dict) or result.get("drvPath") != target["rootDrvPath"] or not isinstance(result.get("outputs"), dict) or set(result["outputs"]) != set(selected_output_names(target)):
                raise RuntimeError("The selected output query differs from the manifest")
            derivation = derivations[target["rootDrvPath"]]
            outputs = {output: store_path(result["outputs"][output]) for output in selected_output_names(target)}
            for output, path in outputs.items():
                data = derivation["outputs"][output]
                if not isinstance(data, dict) or ("path" in data and store_path(data["path"], basename=True) != path):
                    raise RuntimeError("The derivation and queried output path differ")
            selected.append({"attr": target["attr"], "rootSuffix": target["rootSuffix"], "system": target["system"], "rootDrvPath": target["rootDrvPath"], "outputs": outputs})
        return selected

    try:
        if results["runnerOs"] != "Linux" or not str(results["runnerImage"]).startswith("ubuntu"):
            raise RuntimeError("Use the hosted Ubuntu runner")
        helper_hash = clean_sources()
        results.update({"trackedSourceCleanBefore": True, "identityHelperSha256": helper_hash})
        if results["workflowCommit"] != args.wrapper_commit:
            raise RuntimeError("The workflow commit differs from its checkout")
        version = read_command(["nix", "--version"])
        if version != "nix (Nix) 2.34.7":
            raise RuntimeError("Use Nix 2.34.7")
        results["nixVersion"] = version
        original_lock, original_lock_hash = lock_file(args.original)
        wrapper_lock, wrapper_lock_hash = lock_file(args.wrapper)
        input_node = wrapper_lock["nodes"][wrapper_lock["nodes"]["root"]["inputs"]["dotfiles"]]
        nested = {key: value for key, value in original_lock["nodes"].items() if key != "root"}
        if input_node["locked"]["rev"] != SOURCE_COMMIT or input_node["inputs"] != original_lock["nodes"]["root"]["inputs"] or len(nested) != 92 or any(without_wrapper_prefix(wrapper_lock["nodes"].get(key)) != value for key, value in nested.items()):
            raise RuntimeError("The immutable input lock differs")
        results.update({"originalLockSha256": original_lock_hash, "wrapperLockSha256": wrapper_lock_hash, "unchangedNestedLockNodes": 92})
        original_ref = str(Path(args.original).resolve())
        wrapper_ref = str(Path(args.wrapper).resolve())
        eval_command = ["nix", "eval", "--json", "--no-write-lock-file"]
        original = measure("original-12-manifest", eval_command + [original_ref + "#cupboardOutputs"])
        reexported = measure("wrapper-original-12-manifest", eval_command + [wrapper_ref + "#cupboardValidationOriginal"])
        complete = measure("wrapper-14-manifest", eval_command + [wrapper_ref + "#cupboardOutputs"])
        if len(original) != 12 or len(complete) != 14 or reexported != original or complete[:-2] != original:
            raise RuntimeError("Original manifest identities differ")
        successful, failing = complete[-2:]
        if successful["rootSuffix"] != f"x86_64-linux/validation-native-success-{args.mode}" or successful["remote"] or successful["bestEffort"] or successful["os"] != "ubuntu-latest" or not failing["remote"] or not failing["bestEffort"] or failing["rootSuffix"] != "x86_64-linux/validation-controlled-failure":
            raise RuntimeError("Fixture metadata differs")
        show = ["nix", "derivation", "show", "--no-write-lock-file"]
        def installables(source, manifest):
            return [source + "#" + target["attr"].removeprefix(".#") for target in manifest]
        original_derivations = measure("original-12-derivations", show + installables(original_ref, original))
        reexported_derivations = measure("wrapper-original-12-derivations", show + installables(wrapper_ref, reexported))
        complete_derivations = measure("wrapper-14-derivations", show + installables(wrapper_ref, complete))
        original_map = derivation_map(original_derivations, original)
        reexported_map = derivation_map(reexported_derivations, reexported)
        complete_map = derivation_map(complete_derivations, complete)
        if original_derivations != reexported_derivations or any(complete_map.get(path) != data for path, data in original_map.items()):
            raise RuntimeError("Original derivation identities differ")
        output_query = ["nix", "build", "--dry-run", "--json", "--no-link", "--no-write-lock-file"]
        def selected_installables(source, manifest):
            return [source + "#" + target["attr"].removeprefix(".#") + "^" + ",".join(selected_output_names(target)) for target in manifest]
        original_query = measure("original-12-selected-outputs", output_query + selected_installables(original_ref, original))
        reexported_query = measure("wrapper-original-12-selected-outputs", output_query + selected_installables(wrapper_ref, reexported))
        complete_query = measure("wrapper-14-selected-outputs", output_query + selected_installables(wrapper_ref, complete))
        original_outputs = selected_outputs(original, original_map, original_query)
        reexported_outputs = selected_outputs(reexported, reexported_map, reexported_query)
        wrapper_outputs = selected_outputs(complete, complete_map, complete_query)
        if original_query != reexported_query or original_query != complete_query[:-2] or original_outputs != reexported_outputs or original_outputs != wrapper_outputs[:-2]:
            raise RuntimeError("Selected output identities differ")
        if lock_file(args.original)[1] != original_lock_hash or lock_file(args.wrapper)[1] != wrapper_lock_hash:
            raise RuntimeError("A lock file changed during verification")
        if clean_sources() != helper_hash:
            raise RuntimeError("The tracked helper changed during verification")
        results["trackedSourceCleanAfter"] = True
        artifacts = {"original-manifest.json": original, "wrapper-original-manifest.json": reexported, "wrapper-manifest.json": complete, "original-derivations.json": original_derivations, "wrapper-original-derivations.json": reexported_derivations, "wrapper-derivations.json": complete_derivations, "original-selected-outputs.json": {"originalQuery": original_query, "wrapperOriginalQuery": reexported_query, "targets": original_outputs}, "wrapper-selected-outputs.json": {"query": complete_query, "targets": wrapper_outputs}}
        encoded = {name: safe(value) for name, value in artifacts.items()}
        results.update({"derivationJsonVersion": 4, "selectedOutputQuery": "nix build --dry-run --json with explicit output selectors", "targetOutputsBuilt": False, "originalTargetCount": 12, "wrapperTargetCount": 14, "completeManifestEqual": True, "completeDerivationsEqual": True, "completeSelectedOutputsEqual": True, "successFixtureStorePath": wrapper_outputs[-2]["outputs"]["out"], "artifactSha256": {name: hashlib.sha256(value.encode()).hexdigest() for name, value in encoded.items()}, "complete": True})
        safe(results)
        for name, value in artifacts.items():
            (out / name).write_text(json.dumps(value, indent=2) + "\n")
    except Exception:
        results["complete"] = False
        results["failure"] = "Identity verification failed; raw diagnostics were discarded"
        raise SystemExit(results["failure"]) from None
    finally:
        (out / "results.json").write_text(safe(results) + "\n")


if __name__ == "__main__":
    main()
