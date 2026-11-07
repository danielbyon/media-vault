#!/usr/bin/env python3
"""Exercise destination selection and Make's execution boundary without simulators."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
UDID = "11111111-1111-4111-8111-111111111111"
OTHER_UDID = "22222222-2222-4222-8222-222222222222"
MAKE = str(Path(subprocess.check_output(
    ["/usr/bin/xcrun", "--find", "make"], text=True).strip()).with_name("gnumake"))
NAME = "iPhone 17"
DESTINATION = "platform=iOS Simulator,name=iPhone 17,OS=27.2"

# Only process boundaries are replaced. The resolver, shell entry point, and
# Make recipes run unchanged against these inventories and command recordings.
TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
tool = pathlib.Path(sys.argv[0]).name
if tool == "swift":
    print("Apple Swift version 6.3")
elif tool == "xcrun":
    if args == ["--find", "swift"]:
        print("/fixture/Xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    elif args[:3] == ["simctl", "list", "devices"]:
        count_file = root / "device-reads"
        count = int(count_file.read_text()) if count_file.exists() else 0
        count_file.write_text(str(count + 1))
        filename = "devices-after.json" if count and (root / "devices-after.json").exists() else "devices.json"
        print((root / filename).read_text())
    elif args[:3] == ["simctl", "list", "runtimes"]:
        if "--json" in args:
            print((root / "runtimes.json").read_text())
        else:
            print("iOS 27.2 (27.2 - 24B8117) - com.apple.CoreSimulator.SimRuntime.iOS-27-2")
    elif args[:4] == ["xcresulttool", "get", "test-results", "summary"]:
        print('{"totalTestCount": 3}')
    else:
        sys.exit("Unexpected xcrun arguments: " + repr(args))
elif tool == "xcodebuild":
    if args == ["-version"]:
        print("Xcode 27.2\nBuild version 27B52")
    elif "-showdestinations" in args:
        scheme = args[args.index("-scheme") + 1]
        print('Destinations compatible with the "' + scheme + '" scheme:')
        print((root / "destinations.txt").read_text())
        print('Destinations incompatible with the "' + scheme + '" scheme:')
        print((root / "ineligible.txt").read_text())
    else:
        with (root / "executed.jsonl").open("a") as stream:
            stream.write(json.dumps(args) + "\n")
        if "-resultBundlePath" in args:
            pathlib.Path(args[args.index("-resultBundlePath") + 1]).mkdir(parents=True)
else:
    sys.exit("Unexpected tool: " + tool)
'''


class DestinationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("xcrun", "xcodebuild", "swift"):
            path = self.bin / name
            path.write_text(TOOL)
            path.chmod(0o755)
        self.wrapper = self.bin / "wrapper"
        self.wrapper.write_text('#!/usr/bin/env bash\nexec "$@"\n')
        self.wrapper.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        DEVELOPER_DIR="/fixture/Xcode", FIXTURE_ROOT=str(self.root),
                        GITHUB_OUTPUT=str(self.root / "outputs"), PYTHONDONTWRITEBYTECODE="1")
        self.devices = {"devices": {RUNTIME: [self.device()]}}
        self.runtimes = {"runtimes": [{"identifier": RUNTIME, "version": "27.2",
                                      "buildversion": "24B8117", "isAvailable": True}]}
        self.destinations = [self.destination()]
        (self.root / "ineligible.txt").write_text("")

    def device(self, name=NAME, udid=UDID, available=True):
        return {"name": name, "udid": udid, "isAvailable": available, "state": "Shutdown"}

    def destination(self, name=NAME, udid=UDID):
        return f"{{ platform:iOS Simulator, arch:arm64, id:{udid}, OS:27.2, name:{name} }}"

    def write_inventory(self):
        (self.root / "devices.json").write_text(json.dumps(self.devices))
        (self.root / "runtimes.json").write_text(json.dumps(self.runtimes))
        (self.root / "destinations.txt").write_text("\n".join(self.destinations))

    def verify(self, expected="", destination=NAME, execute=False):
        self.write_inventory()
        command = ["bash", str(ROOT / "Scripts/verify-xcode-27.2-destination.sh"), destination, expected]
        if execute:
            command += ["--", "xcodebuild", "-workspace", "App.xcworkspace", "-scheme", "App", "test"]
        return subprocess.run(command, env=self.env, cwd=ROOT, text=True, capture_output=True)

    def executions(self):
        path = self.root / "executed.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_rejected(self, **kwargs):
        result = self.verify(**kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.executions(), [])

    def test_exact_valid_device_returns_verified_udid(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], UDID)
        self.assertIn(f"simulator_udid={UDID}", (self.root / "outputs").read_text())

    def test_similar_name_suffix_is_rejected(self):
        self.devices["devices"][RUNTIME] = [self.device(name="iPhone 17 Pro")]
        self.destinations = [self.destination(name="iPhone 17 Pro")]
        self.assert_rejected()

    def test_similar_name_prefix_is_rejected(self):
        self.devices["devices"][RUNTIME] = [self.device(name="Test iPhone 17")]
        self.destinations = [self.destination(name="Test iPhone 17")]
        self.assert_rejected()

    def test_exact_name_under_wrong_runtime_is_rejected(self):
        self.devices["devices"] = {"com.apple.CoreSimulator.SimRuntime.iOS-27-1": [self.device()]}
        self.assert_rejected()

    def test_wrong_runtime_build_is_rejected(self):
        self.runtimes["runtimes"][0]["buildversion"] = "24B9999"
        self.assert_rejected()

    def test_unavailable_device_is_rejected(self):
        self.devices["devices"][RUNTIME][0]["isAvailable"] = False
        self.assert_rejected()

    def test_ambiguous_exact_names_are_rejected(self):
        self.devices["devices"][RUNTIME].append(self.device(udid=OTHER_UDID))
        self.destinations.append(self.destination(udid=OTHER_UDID))
        self.assert_rejected()

    def test_explicit_udid_disambiguates_exact_names(self):
        self.devices["devices"][RUNTIME].append(self.device(udid=OTHER_UDID))
        self.destinations.append(self.destination(udid=OTHER_UDID))
        result = self.verify(expected=OTHER_UDID)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], OTHER_UDID)

    def test_explicit_mismatching_udid_is_rejected(self):
        self.assert_rejected(expected=OTHER_UDID)

    def test_device_absent_from_scheme_destinations_is_rejected(self):
        self.destinations = [self.destination(udid=OTHER_UDID)]
        self.assert_rejected()

    def test_ineligible_destination_is_rejected(self):
        self.destinations = []
        (self.root / "ineligible.txt").write_text(self.destination())
        self.assert_rejected()

    def test_bracketed_macos_variant_does_not_hide_valid_simulator(self):
        self.destinations.insert(0, "{ platform:macOS, arch:arm64, "
                                 "variant:Designed for [iPad,iPhone], "
                                 "id:00006040-000A298921A0801C, name:My Mac }")
        result = self.verify(expected=UDID, execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        executed, = self.executions()
        self.assertEqual(executed[executed.index("-destination") + 1],
                         "platform=iOS Simulator,id=11111111-1111-4111-8111-111111111111")

    def test_unbalanced_destination_brackets_are_rejected(self):
        for variant in ("Designed for [iPad,iPhone", "Designed for iPad,iPhone]"):
            with self.subTest(variant=variant):
                self.destinations = [f"{{ platform:macOS, variant:{variant}, name:My Mac }}",
                                     self.destination()]
                self.assert_rejected(execute=True)

    def test_malformed_destination_field_is_rejected(self):
        self.destinations.insert(0, "{ platform:macOS, invalid field, name:My Mac }")
        self.assert_rejected(execute=True)

    def test_duplicate_destination_field_is_rejected(self):
        self.destinations.insert(0, "{ platform:macOS, name:My Mac, name:Other Mac }")
        self.assert_rejected(execute=True)

    def test_unsupported_destination_is_rejected(self):
        self.assert_rejected(destination="platform=macOS,name=iPhone 17,OS=27.2")

    def test_verified_device_unavailable_before_execution_is_rejected(self):
        (self.root / "devices-after.json").write_text(json.dumps({"devices": {RUNTIME: [self.device(available=False)]}}))
        self.assert_rejected(expected=UDID, execute=True)

    def test_verified_udid_reaches_actual_xcodebuild_arguments(self):
        result = self.verify(expected=UDID, execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        executed, = self.executions()
        self.assertEqual(executed[executed.index("-destination") + 1],
                         "platform=iOS Simulator,id=11111111-1111-4111-8111-111111111111")

    def test_make_binds_both_schemes_to_one_device_for_each_target(self):
        checkout = self.root / "checkout"
        checkout.mkdir()
        shutil.copy2(ROOT / "Makefile", checkout / "Makefile")
        (checkout / "Scripts").symlink_to(ROOT / "Scripts", target_is_directory=True)
        for target, name in (("test", NAME), ("test-snapshots", "iPad Pro 11-inch (M5)")):
            with self.subTest(target=target):
                self.devices = {"devices": {RUNTIME: [self.device(name=name)]}}
                self.destinations = [self.destination(name=name)]
                self.write_inventory()
                (self.root / "executed.jsonl").unlink(missing_ok=True)
                result = subprocess.run([MAKE, target, f"XCODE_WRAPPER={self.wrapper}",
                                         f"VERIFIED_SIMULATOR_UDID={UDID}", f"PATH={self.env['PATH']}"],
                                        cwd=checkout, env=self.env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                commands = self.executions()
                self.assertEqual([args[args.index("-scheme") + 1] for args in commands],
                                 ["App", "ApplicationFoundation-Package"])
                self.assertEqual([args[args.index("-destination") + 1] for args in commands],
                                 ["platform=iOS Simulator,id=11111111-1111-4111-8111-111111111111"] * 2)


if __name__ == "__main__":
    unittest.main()
