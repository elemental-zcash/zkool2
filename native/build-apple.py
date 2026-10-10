#!/usr/bin/env python3
"""Build UniFFI Swift bindings and an iOS XCFramework; requires full Xcode."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parent
MANIFEST = ROOT / "rust" / "Cargo.toml"
IOS_DEPLOYMENT_TARGET = "16.0"  # Keep aligned with ios/project.yml.


def run(*args, env=None):
    subprocess.run(args, cwd=WORKSPACE, check=True, env=env)


def ios_build_environment(triple):
    sdk = "iphonesimulator" if triple == "aarch64-apple-ios-sim" else "iphoneos"
    environment = os.environ.copy()
    # Both rustc and cc-rs read this. Without it rustc can link for iOS 10
    # while C dependencies inherit the SDK version as their deployment target.
    environment["IPHONEOS_DEPLOYMENT_TARGET"] = IOS_DEPLOYMENT_TARGET
    environment["SDKROOT"] = subprocess.check_output(
        ["xcrun", "--sdk", sdk, "--show-sdk-path"], cwd=WORKSPACE, text=True
    ).strip()
    return environment


def workspace_metadata():
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--manifest-path", str(WORKSPACE / "Cargo.toml"),
         "--format-version", "1", "--no-deps"], cwd=WORKSPACE
    ))
    native = next((package for package in metadata["packages"]
                   if Path(package["manifest_path"]).resolve() == MANIFEST.resolve()), None)
    if native is None or native["id"] not in metadata["workspace_members"]:
        raise SystemExit(
            f"Native crate is missing from the Cargo workspace at {WORKSPACE / 'Cargo.toml'}.\n"
            'Add "native/rust" to [workspace].members alongside "rust".\n'
            "The native/ directory must be copied together with the root Cargo.toml,\n"
            "Cargo.lock, and the rust/ graphql-core integration changes."
        )
    core = next((package for package in metadata["packages"]
                 if Path(package["manifest_path"]).resolve() == (WORKSPACE / "rust" / "Cargo.toml").resolve()), None)
    if core is None or "graphql-core" not in core["features"]:
        raise SystemExit(
            f"Missing graphql-core feature in {WORKSPACE / 'rust' / 'Cargo.toml'}.\n"
            "Apply the rust/ integration changes as well as the native/ directory;\n"
            "see native/README.md for the required files."
        )
    return metadata


def cargo(*args, env=None):
    # Select the package by its manifest, independently of workspace defaults.
    run("cargo", args[0], "--manifest-path", str(MANIFEST), *args[1:], env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bindings-only", action="store_true", help="Generate Swift on macOS without an iOS SDK")
    parser.add_argument("--simulator-only", action="store_true", help="Build only the Apple Silicon simulator slice")
    parser.add_argument("--check", action="store_true", help="Check Cargo workspace integration without building or requiring Xcode")
    parser.add_argument("--clean-ios", action="store_true", help="Rebuild iOS release artifacts after SDK or deployment-target changes")
    args = parser.parse_args()
    metadata = workspace_metadata()
    if args.check:
        print(f"Native Cargo workspace integration OK: {MANIFEST}")
        return
    if not args.bindings_only:
        run("xcodebuild", "-version")
    target = Path(metadata["target_directory"])
    cargo("build", "--locked", "--lib")
    generated = ROOT / "ios" / "Generated"
    generated.mkdir(parents=True, exist_ok=True)
    cargo("run", "--locked", "--features", "bindgen",
        "--bin", "zkool-bindgen", "--", "generate", "--library",
        str(target / "debug" / "libzkool_native.dylib"), "--metadata-no-deps", "--language", "swift",
        "--config", str(ROOT / "rust" / "uniffi.toml"), "--out-dir", str(generated))
    if args.bindings_only:
        return
    triples = ["aarch64-apple-ios-sim"] if args.simulator_only else ["aarch64-apple-ios", "aarch64-apple-ios-sim"]
    headers = generated / "Headers"
    headers.mkdir(exist_ok=True)
    for header in generated.glob("*.h"):
        shutil.copy2(header, headers / header.name)
    shutil.copy2(generated / "ZkoolNativeFFI.modulemap", headers / "module.modulemap")
    command = ["xcodebuild", "-create-xcframework"]
    for triple in triples:
        run("rustup", "target", "add", triple)
        environment = ios_build_environment(triple)
        if args.clean_ios:
            cargo("clean", "--release", "--target", triple, env=environment)
        cargo("build", "--locked", "--lib", "--release", "--target", triple, env=environment)
        command += ["-library", str(target / triple / "release" / "libzkool_native.a"), "-headers", str(headers)]
    frameworks = ROOT / "ios" / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    output = frameworks / "ZkoolNativeFFI.xcframework"
    if output.exists():
        shutil.rmtree(output)
    run(*command, "-output", str(output))
    subprocess.run(["xcodegen", "generate"], cwd=ROOT / "ios", check=True)


if __name__ == "__main__":
    main()
