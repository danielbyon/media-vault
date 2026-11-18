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
        bundle = pathlib.Path(args[args.index("--path") + 1])
        summary = bundle / "summary.json"
        print(summary.read_text() if summary.exists() else '{"totalTestCount": 3}')
        if os.environ.get("SCENARIO") == "summary-error": sys.exit(2)
    elif args[:3] == ["xcresulttool", "export", "attachments"]:
        bundle = pathlib.Path(args[args.index("--path") + 1])
        output = pathlib.Path(args[args.index("--output-path") + 1])
        __import__("shutil").copytree(bundle / "exports", output, dirs_exist_ok=True)
        if os.environ.get("SCENARIO") == "export-error": sys.exit(2)
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
            if os.environ.get("SCENARIO") == "missing-bundle": sys.exit(0)
            bundle = pathlib.Path(args[args.index("-resultBundlePath") + 1])
            bundle.mkdir(parents=True)
            if os.environ.get("TEST_RUNNER_NATIVE_SNAPSHOT_QUALIFICATION") == "1":
                with (root / "environment.jsonl").open("a") as stream:
                    stream.write(json.dumps(dict(os.environ)) + "\n")
                hosted = "Hosted" in bundle.name
                scenario = os.environ.get("SCENARIO", "")
                summary = dict(totalTestCount=1 if hosted else 4, passedTests=1 if hosted else 4,
                               failedTests=0, skippedTests=0)
                if scenario == "zero": summary["totalTestCount"] = 0
                if scenario == "bad-summary": summary = "not a summary"
                if scenario == "boolean-count": summary["skippedTests"] = False
                if scenario == "skipped": summary["skippedTests"] = 1
                if scenario == "failed": summary["failedTests"] = 1
                if scenario == "extra": summary["totalTestCount"] += 1
                if scenario == "missing-count": del summary["skippedTests"]
                (bundle / "summary.json").write_text(json.dumps(summary))
                exports = bundle / "exports"
                exports.mkdir()
                captures = ([f"root-content-v1-{content}-{layout}" for content in ("calculator", "library")
                             for layout in ("compact-iphone", "regular-ipad")] * 2 if hosted else
                            ["compactPhoneSnapshot()", "largePhoneSnapshot()", "regularWidthIPadSnapshot()"])
                manifest = []
                for index, capture in enumerate(captures):
                    method = ("AppHostedUITests/ScenePrivacyCoverTests/"
                              "rootPresentationSnapshotsCoverPrimaryShellStates()" if hosted else
                              "RootSurfaceSnapshotTests/" + capture)
                    receipt = dict(schemaVersion=1, qualification="1",
                                   expectedScale=os.environ["TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE"],
                                   recordMode="never", nativeScale=int(os.environ["TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE"]),
                                   referenceScale=int(os.environ["TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE"]),
                                   capture=capture, target="AppHostedTests" if hosted else "AppTests",
                                   processID=123, processName="TestHost", validationError=None)
                    mutations = {"scale": ("nativeScale", 2 if receipt["nativeScale"] == 3 else 3),
                                 "reference": ("referenceScale", 1), "qualification": ("qualification", None),
                                 "expected": ("expectedScale", "2"), "record": ("recordMode", "all"),
                                 "validation": ("validationError", "bad environment"), "schema": ("schemaVersion", True),
                                 "pid": ("processID", 0), "process": ("processName", ""),
                                 "target": ("target", "Other"), "capture": ("capture", "Other")}
                    if scenario in mutations:
                        key, value = mutations[scenario]
                        receipt[key] = value
                    filename = (f"opaque-{index}.json" if scenario == "opaque-filenames" else
                                f"native-snapshot-environment-{index}.json")
                    (exports / filename).write_text("{" if scenario == "bad-json" else json.dumps(receipt))
                    attachment = dict(exportedFileName=filename, suggestedHumanReadableName=f"native-snapshot-environment_{index}.json")
                    if scenario == "missing-file": (exports / filename).unlink()
                    manifest.append(dict(testIdentifier="Wrong/method()" if scenario == "attribution" else method,
                                         attachments=[attachment]))
                if scenario == "missing": manifest.pop()
                if scenario == "duplicate": manifest.append(manifest[0])
                (exports / "manifest.json").write_text("{" if scenario == "bad-manifest" else json.dumps(manifest))
                if scenario == "no-manifest": (exports / "manifest.json").unlink()
                if scenario == "xcode-failure" and not hosted: sys.exit(65)
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

    def test_make_binds_each_invocation_to_its_expected_destination(self):
        checkout = self.root / "checkout"
        checkout.mkdir()
        shutil.copy2(ROOT / "Makefile", checkout / "Makefile")
        (checkout / "Scripts").symlink_to(ROOT / "Scripts", target_is_directory=True)
        ipad_name = "iPad Pro 11-inch (M5)"
        for target in ("test", "test-snapshots"):
            with self.subTest(target=target):
                if target == "test":
                    ipad_udid = OTHER_UDID
                    self.devices = {"devices": {RUNTIME: [
                        self.device(name=NAME, udid=UDID),
                        self.device(name=ipad_name, udid=ipad_udid),
                    ]}}
                    self.destinations = [
                        self.destination(name=NAME, udid=UDID),
                        self.destination(name=ipad_name, udid=ipad_udid),
                    ]
                    expected_schemes = ["App", "ApplicationFoundation-Package", "App"]
                    expected_udids = [UDID, UDID, ipad_udid]
                else:
                    self.devices = {"devices": {RUNTIME: [self.device(name=ipad_name)]}}
                    self.destinations = [self.destination(name=ipad_name)]
                    expected_schemes = ["App", "ApplicationFoundation-Package"]
                    expected_udids = [UDID, UDID]
                self.write_inventory()
                (self.root / "executed.jsonl").unlink(missing_ok=True)
                result = subprocess.run([MAKE, target, f"XCODE_WRAPPER={self.wrapper}",
                                         f"VERIFIED_SIMULATOR_UDID={UDID}", f"PATH={self.env['PATH']}"],
                                        cwd=checkout, env=self.env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                commands = self.executions()
                self.assertEqual([args[args.index("-scheme") + 1] for args in commands],
                                 expected_schemes)
                self.assertEqual([args[args.index("-destination") + 1].rsplit("=", 1)[-1]
                                  for args in commands], expected_udids)


    def native_run(self, scenario="", scale="3", **overrides):
        checkout = self.root / "native-checkout"
        checkout.mkdir(exist_ok=True)
        shutil.copy2(ROOT / "Makefile", checkout / "Makefile")
        scripts = checkout / "Scripts"
        if not scripts.exists():
            scripts.symlink_to(ROOT / "Scripts", target_is_directory=True)
        self.write_inventory()
        self.env.update(SCENARIO=scenario, NATIVE_SNAPSHOT_QUALIFICATION="ambient",
                        NATIVE_SNAPSHOT_EXPECTED_SCALE="ambient", SNAPSHOT_TESTING_RECORD="all")
        command = [MAKE, "test-native-snapshots", f"XCODE_WRAPPER={self.wrapper}",
                   f"PATH={self.env['PATH']}", f"NATIVE_SNAPSHOT_EXPECTED_SCALE={scale}",
                   f"NATIVE_SNAPSHOT_BUILD_DIRECTORY={self.root / 'external build'}",
                   f"TEST_RESULTS_DIRECTORY={self.root / 'evidence'}",
                   f"SOURCE_PACKAGES_DIRECTORY={self.root / 'package cache'}"]
        command += [f"{key}={value}" for key, value in overrides.items()]
        return subprocess.run(command, cwd=checkout, env=self.env, text=True, capture_output=True)

    def test_native_recipe_validates_and_preserves_both_bundles(self):
        result = self.native_run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = self.executions()
        self.assertEqual(len(commands), 2)
        selectors = [next(arg for arg in args if arg.startswith("-only-testing:")) for args in commands]
        self.assertEqual(selectors, ["-only-testing:AppTests/RootSurfaceSnapshotTests",
                                    "-only-testing:AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/"
                                    "rootPresentationSnapshotsCoverPrimaryShellStates()"])
        for args in commands:
            self.assertEqual(args[args.index("-scheme") + 1], "App")
            self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "NO")
            self.assertEqual(args[args.index("-collect-test-diagnostics") + 1], "never")
            self.assertTrue(args[args.index("-derivedDataPath") + 1].startswith(str(self.root / "external build")))
            self.assertEqual(args[args.index("-clonedSourcePackagesDirPath") + 1], str(self.root / "package cache"))
        self.assertEqual(commands[0][commands[0].index("-derivedDataPath") + 1],
                         commands[1][commands[1].index("-derivedDataPath") + 1])
        environments = [json.loads(line) for line in (self.root / "environment.jsonl").read_text().splitlines()]
        for env in environments:
            for key in ("NATIVE_SNAPSHOT_QUALIFICATION", "NATIVE_SNAPSHOT_EXPECTED_SCALE", "SNAPSHOT_TESTING_RECORD"):
                self.assertNotIn(key, env)
            self.assertEqual(env["TEST_RUNNER_NATIVE_SNAPSHOT_QUALIFICATION"], "1")
            self.assertEqual(env["TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE"], "3")
            self.assertEqual(env["TEST_RUNNER_SNAPSHOT_TESTING_RECORD"], "never")
        self.assertEqual(len(list((self.root / "evidence").glob("*/*.xcresult"))), 2)
        self.assertEqual(len(list((self.root / "evidence").glob("*/*-attachments/manifest.json"))), 2)

    def test_native_recipe_accepts_explicit_2x_destination(self):
        name = "iPad Pro 11-inch (M5)"
        self.devices = {"devices": {RUNTIME: [self.device(name=name)]}}
        self.destinations = [self.destination(name=name)]
        result = self.native_run(scale="2", NATIVE_SNAPSHOT_DESTINATION=f"platform=iOS Simulator,name={name},OS=27.2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_native_recipe_keeps_wrapper_chatter_out_of_summary_json(self):
        self.wrapper.write_text('#!/usr/bin/env bash\n'
                                'printf "Verified simulator runtime: fixture\\n"\n'
                                'exec "$@"\n')
        result = self.native_run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        evidence, = (self.root / "evidence").iterdir()
        for target, count in (("AppTests", 4), ("AppHostedTests", 1)):
            summary = json.loads((evidence / f"{target}-summary.json").read_text())
            self.assertEqual(summary["totalTestCount"], count)
            self.assertIn("Verified simulator runtime: fixture",
                          (evidence / f"{target}-summary.log").read_text())
        self.assertEqual(len(self.executions()), 2)

    def test_native_recipe_uses_suggested_name_for_opaque_exports(self):
        result = self.native_run("opaque-filenames")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_native_recipe_keeps_fresh_evidence_for_each_run(self):
        for _ in range(2):
            result = self.native_run()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(list((self.root / "evidence").glob("*/*.xcresult"))), 4)

    def test_native_recipe_checks_evidence_with_python_optimization_enabled(self):
        self.env["PYTHONOPTIMIZE"] = "1"
        result = self.native_run("validation")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.executions()), 2)

    def test_native_recipe_retains_default_evidence_after_build_cleanup(self):
        result = self.native_run(TEST_RESULTS_DIRECTORY="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build = self.root / "external build"
        self.assertEqual(len(list((build / "TestResults").glob("*/*.xcresult"))), 2)
        self.assertEqual(list(build.glob("xcodebuild-native-snapshot.*")), [])

    def test_native_recipe_rejects_bad_evidence_and_attempts_both(self):
        for scenario in ("zero", "extra", "skipped", "failed", "missing-count", "bad-summary", "boolean-count", "scale", "reference",
                         "qualification", "expected", "record", "validation", "schema", "pid", "process",
                         "target", "capture", "missing", "duplicate", "attribution", "bad-json",
                         "missing-file", "bad-manifest", "no-manifest", "xcode-failure",
                         "missing-bundle", "summary-error", "export-error"):
            with self.subTest(scenario=scenario):
                (self.root / "executed.jsonl").unlink(missing_ok=True)
                result = self.native_run(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(self.executions()), 2, result.stdout + result.stderr)

    def test_native_recipe_rejects_unsupported_scale_before_execution(self):
        result = self.native_run(scale="4")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.executions(), [])


if __name__ == "__main__":
    unittest.main()
