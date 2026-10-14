#!/usr/bin/env python3
"""Build and verify the app's isolated Debug contracts on an explicit Simulator."""

import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.stefan.myvoicememo"


class CheckFailure(Exception):
    pass


def contract_manifest():
    manifest = json.loads((ROOT / "Scripts/simulator-checks.json").read_text())
    contracts = manifest["contracts"]
    names = [item["name"] for item in contracts]
    app = (ROOT / "Sources/App/VoiceMemoApp.swift").read_text()
    registered = re.findall(r"await\s+(\w+)\.runFromLaunchArguments\s*\(", app)
    registered = [name for name in registered if name != "LocalModelProbe"]
    if not contracts or len(names) != len(set(names)) or names != registered:
        raise CheckFailure("Contract manifest does not match every app launch hook, in order. Update Scripts/simulator-checks.json.")
    if len({item["marker"] for item in contracts}) != len(contracts):
        raise CheckFailure("Contract success markers must be unique.")
    for item in contracts:
        source = (ROOT / f"Sources/App/{item['name']}.swift").read_text()
        marker = item["marker"]
        literal = json.dumps(marker, ensure_ascii=False)
        prefix, separator, message = marker.partition(": ")
        logged = f'log({json.dumps(prefix)}, {json.dumps(message)})'
        if not item["flag"].endswith("-contract-tests") or json.dumps(item["flag"]) not in source:
            raise CheckFailure(f"Missing source launch flag for {item['name']}.")
        if literal not in source and (not separator or logged not in source):
            raise CheckFailure(f"Success marker changed for {item['name']}; update the manifest.")
    return contracts


def stop_process(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def command(arguments, log, timeout=60, allow_failure=False):
    with log.open("w") as output:
        process = subprocess.Popen(arguments, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise CheckFailure(f"Command timed out after {timeout:g}s: {arguments[0]}. Log: {log}") from error
        finally:
            stop_process(process)
    if status and not allow_failure:
        raise CheckFailure(f"Command exited {status}: {' '.join(arguments[:3])}. Log: {log}")
    return status


def prepare_device(device, artifacts):
    log = artifacts / "devices.json"
    command(["xcrun", "simctl", "list", "devices", "available", "--json"], log)
    devices = json.loads(log.read_text())["devices"]
    matches = [(runtime, item) for runtime, items in devices.items() for item in items if item["udid"].upper() == device]
    if len(matches) != 1 or not matches[0][1].get("isAvailable") or ".iOS-" not in matches[0][0]:
        raise CheckFailure("--device must identify one available iOS Simulator. See xcrun simctl list devices available.")
    runtime, item = matches[0]
    print(f"Simulator: {item['name']} ({device}); {runtime}", flush=True)
    if item["state"] == "Shutdown":
        command(["xcrun", "simctl", "boot", device], artifacts / "boot.log")
    elif item["state"] != "Booted":
        raise CheckFailure(f"Simulator is {item['state']}; wait until it is shut down or booted, then retry.")
    command(["xcrun", "simctl", "bootstatus", device, "-b"], artifacts / "bootstatus.log", timeout=120)


def application(args, artifacts):
    if args.app:
        app = args.app.resolve()
    else:
        derived = artifacts / "DerivedData"
        print(f"Building Debug. Log: {artifacts / 'build.log'}", flush=True)
        command(["xcodebuild", "-project", str(ROOT / "VoiceMemo.xcodeproj"), "-scheme", "VoiceMemo",
                 "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={args.device}",
                 "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "build"],
                artifacts / "build.log", timeout=args.build_timeout)
        app = derived / "Build/Products/Debug-iphonesimulator/MyVoiceMemo.app"
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    executable = info.get("CFBundleExecutable", "")
    if info.get("CFBundleIdentifier") != BUNDLE or "iPhoneSimulator" not in info.get("CFBundleSupportedPlatforms", []):
        raise CheckFailure("--app must be the MyVoiceMemo iOS Simulator Debug bundle.")
    if not executable or Path(executable).name != executable or not (app / executable).is_file():
        raise CheckFailure("The Simulator app executable is missing.")
    return app


def terminate_app(device, log, required=False):
    status = command(["xcrun", "simctl", "terminate", device, BUNDLE], log, timeout=15, allow_failure=True)
    if required and status:
        output = log.read_text(errors="replace")
        if "not running" not in output.lower() and "No such process" not in output:
            raise CheckFailure(f"Could not confirm app cleanup. Log: {log}")


def run_app(device, flags, markers, artifacts, name, timeout):
    log = artifacts / f"{name}.log"
    terminate_app(device, artifacts / f"{name}-before.log")
    started = time.monotonic()
    print(f"Running {name}. Log: {log}", flush=True)
    with log.open("w") as output:
        process = subprocess.Popen(["xcrun", "simctl", "launch", "--terminate-running-process", "--console",
                                    device, BUNDLE, "-demo", *flags], stdout=output, stderr=subprocess.STDOUT,
                                   cwd=ROOT, start_new_session=True)
        try:
            while True:
                lines = log.read_text(errors="replace").splitlines()
                if any("Fatal error:" in line or line.startswith("FAIL Contract · ") for line in lines):
                    raise CheckFailure(f"{name} reported a failed check. Log: {log}")
                if process.poll() not in (None, 0):
                    raise CheckFailure(f"{name} process exited {process.returncode}. Log: {log}")
                if all(marker in lines for marker in markers):
                    if any(lines.count(marker) != 1 for marker in markers):
                        raise CheckFailure(f"{name} emitted duplicate success markers. Log: {log}")
                    break
                if process.poll() is not None or time.monotonic() - started >= timeout:
                    missing = [marker.split(":", 1)[0] for marker in markers if marker not in lines]
                    raise CheckFailure(f"{name} exited or timed out before all checks completed. Missing: {', '.join(missing)}. Log: {log}")
                time.sleep(0.25)
        finally:
            try:
                terminate_app(device, artifacts / f"{name}-cleanup.log", required=True)
            finally:
                stop_process(process)
    for marker in markers:
        print(marker)
    elapsed = time.monotonic() - started
    print(f"{name} passed in {elapsed:.1f}s.", flush=True)
    return elapsed


def positive_seconds(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a positive finite number of seconds")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="Explicit iOS Simulator UUID; never selected automatically")
    parser.add_argument("--app", type=Path, help="Existing MyVoiceMemo.app Debug Simulator bundle; skips building")
    parser.add_argument("--artifacts", type=Path, help="New output directory (default: a new system temporary directory)")
    parser.add_argument("--timeout", type=positive_seconds, default=180, help="Deadline per app run in seconds (default: 180)")
    parser.add_argument("--build-timeout", type=positive_seconds, default=600, help="Build deadline in seconds (default: 600)")
    parser.add_argument("--list", action="store_true", help="Validate and list checks without touching a Simulator")
    args = parser.parse_args()
    contracts = contract_manifest()
    if args.list:
        for item in contracts:
            print(f"{item['flag']}: {item['name']}")
        print(f"{len(contracts)} contract suites")
        return
    if not args.device:
        parser.error("--device is required")
    try:
        args.device = str(uuid.UUID(args.device)).upper()
    except ValueError:
        parser.error("--device must be an explicit Simulator UUID")
    if args.artifacts:
        artifacts = args.artifacts.resolve()
        artifacts.mkdir(parents=True, exist_ok=False)
    else:
        artifacts = Path(tempfile.mkdtemp(prefix="myvoicememo-checks-"))
    print(f"Artifacts: {artifacts}", flush=True)
    prepare_device(args.device, artifacts)
    app = application(args, artifacts)
    terminate_app(args.device, artifacts / "before-install.log")
    command(["xcrun", "simctl", "install", args.device, str(app)], artifacts / "install.log", timeout=120)
    flags = list(dict.fromkeys(item["flag"] for item in contracts))
    contract_time = run_app(args.device, flags, [item["marker"] for item in contracts], artifacts, "contracts", args.timeout)
    summary = {"device": args.device, "app": str(app), "contracts": len(contracts),
               "contract_seconds": contract_time, "status": "passed"}
    (artifacts / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS: {len(contracts)} contract suites. Artifacts: {artifacts}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Interrupted; owned app/process cleanup attempted.", file=sys.stderr)
        sys.exit(130)
    except (CheckFailure, OSError, ValueError, KeyError, IndexError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
