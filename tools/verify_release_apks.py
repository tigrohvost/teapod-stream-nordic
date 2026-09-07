#!/usr/bin/env python3
"""Validate the actual split APKs and write a public release manifest."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

RELEASE_CERT = "05a8e6930d302cfed4817b23930e6deac77b399dbaa9b53218d08adf97c1a407"
ABI_OFFSETS = {"armeabi-v7a": 1000, "arm64-v8a": 2000, "x86_64": 4000}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk-dir", type=Path, default=Path("build/app/outputs/flutter-apk"))
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--require-release-signature", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha):
        raise SystemExit("Expected a full source commit SHA")
    version, build_number = re.search(
        r"^version:\s*(\S+)\+(\d+)\s*$", Path("pubspec.yaml").read_text(), re.M
    ).groups()
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
    candidates = [path for path in (sdk / "build-tools").iterdir()
                  if (path / "apksigner").exists() and (path / "aapt").exists()]
    build_tools = max(candidates, key=lambda path: tuple(map(int, re.findall(r"\d+", path.name))))
    files = []
    signer = None
    for abi, offset in ABI_OFFSETS.items():
        apk = args.apk_dir / f"teapod-stream-{abi}.apk"
        if not apk.is_file() or apk.stat().st_size == 0:
            raise SystemExit(f"Missing APK: {apk}")
        cert_output = run(str(build_tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk))
        # Build-tools 37 labels this "V2 Signer:", older tools use "Signer #1".
        certificates = set(re.findall(
            r"^(?:Signer #\d+|V\d+(?:\.\d+)? Signer):? certificate SHA-256 digest: ([0-9a-fA-F]+)$",
            cert_output, re.M))
        if len(certificates) != 1:
            raise SystemExit(f"Expected one APK signer: {apk.name}")
        certificate = certificates.pop().lower()
        if args.require_release_signature and certificate != RELEASE_CERT:
            raise SystemExit(f"Release signing certificate mismatch: {apk.name}")
        if signer is not None and certificate != signer:
            raise SystemExit("APK architectures have different signing certificates")
        signer = certificate
        badging = run(str(build_tools / "aapt"), "dump", "badging", str(apk))
        package = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
        expected_code = int(build_number) + offset  # Flutter 3.41 split-per-ABI scheme.
        if package is None or package.groups() != (
                "com.teapodstream.teapodstream", str(expected_code), version):
            raise SystemExit(f"Wrong package/version in {apk.name}")
        if "application-debuggable" in badging:
            raise SystemExit(f"Debuggable APK: {apk.name}")
        with zipfile.ZipFile(apk) as archive:
            names = set(archive.namelist())
            required = {
                f"lib/{abi}/libapp.so", f"lib/{abi}/libflutter.so", f"lib/{abi}/libgojni.so",
                "assets/flutter_assets/assets/binaries/geoip.dat",
                "assets/flutter_assets/assets/binaries/geosite.dat",
                "assets/flutter_assets/assets/brave_opossum.png",
            }
            for family in ("InterTight", "JetBrainsMono"):
                for weight in ("Regular", "Medium", "SemiBold", "Bold"):
                    required.add(f"assets/flutter_assets/assets/fonts/{family}-{weight}.ttf")
            if missing := required - names:
                raise SystemExit(f"Missing bundled assets in {apk.name}: {sorted(missing)}")
            native_abis = {name.split('/')[1] for name in names if name.startswith('lib/') and name.endswith('.so')}
            if native_abis != {abi}:
                raise SystemExit(f"Wrong native architecture in {apk.name}: {native_abis}")
            if any(archive.getinfo(name).file_size == 0 for name in required):
                raise SystemExit(f"Empty runtime asset in {apk.name}")
        files.append({"name": apk.name, "abi": abi, "version_code": expected_code,
                      "size": apk.stat().st_size, "sha256": digest(apk)})
        print(f"Verified {apk.name}: {version} ({expected_code}), signed, release assets present")
    manifest = {
        "version": version, "source_sha": args.source_sha,
        "signer_sha256": signer,
        "teapod_core": Path(".github/teapod-core-version.txt").read_text().strip(),
        "teapod_core_sha256": digest(Path("android/app/libs/teapod-core.aar")),
        "apks": files,
    }
    (args.apk_dir / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.apk_dir / "SHA256SUMS").write_text("".join(f"{item['sha256']}  {item['name']}\n" for item in files))


if __name__ == "__main__":
    main()
