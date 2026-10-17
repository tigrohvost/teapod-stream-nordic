#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

fail() { echo "$*" >&2; exit 1; }
command -v python3 >/dev/null || fail 'Python 3.11+ is required'
# tools/*.py use hashlib.file_digest (3.11+).
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' \
  || fail "Python 3.11+ is required, found $(python3 --version 2>&1)"

lock_value() {
  python3 -c 'import json,sys; print(json.load(open("dependencies.lock.json"))["toolchain"][sys.argv[1]])' "$1"
}

setup_environment() {
  local java_version flutter_version
  java_version="$(lock_value java)"
  flutter_version="$(lock_value flutter)"
  local java_help="Install JDK $java_version (e.g. Temurin: https://adoptium.net/temurin/releases/?version=$java_version) and point JAVA_HOME at it"
  if [[ -z "${JAVA_HOME:-}" ]]; then
    if [[ "$(uname -s)" == Darwin && -x /usr/libexec/java_home ]]; then
      JAVA_HOME="$(/usr/libexec/java_home -v "$java_version")"
    elif command -v java >/dev/null; then
      JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    else fail "No JDK found. $java_help"; fi
  fi
  if [[ -z "${ANDROID_HOME:-}" ]]; then
    ANDROID_HOME="${ANDROID_SDK_ROOT:-}"
    if [[ -z "$ANDROID_HOME" ]]; then
      case "$(uname -s)" in
        Darwin) ANDROID_HOME="$HOME/Library/Android/sdk" ;;
        Linux) ANDROID_HOME="$HOME/Android/Sdk" ;;
        *) fail 'Set ANDROID_HOME for this platform' ;;
      esac
    fi
  fi
  ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
  export JAVA_HOME ANDROID_HOME ANDROID_SDK_ROOT
  [[ -x "$JAVA_HOME/bin/java" ]] || fail "JAVA_HOME=$JAVA_HOME has no bin/java. $java_help"
  [[ -d "$ANDROID_HOME/platforms" ]] || fail "No Android SDK at ANDROID_HOME=$ANDROID_HOME"
  local found
  found="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
  [[ "$found" =~ version\ \"$java_version[.\"] ]] \
    || fail "JDK $java_version is required (dependencies.lock.json), JAVA_HOME has: $found. $java_help"
  command -v flutter >/dev/null \
    || fail "Flutter $flutter_version is required: https://docs.flutter.dev/release/archive — add its bin/ to PATH"
  found="$(flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
  [[ "$found" == "$flutter_version" ]] \
    || fail "Flutter $flutter_version is required (dependencies.lock.json), PATH has $found"
}

prepare() {
  setup_environment
  python3 tools/dependencies.py fetch
  flutter pub get --enforce-lockfile
}

case "${1:-help}" in
  binaries) python3 tools/dependencies.py fetch ;;
  debug) prepare; flutter build apk --debug --split-per-abi --no-pub ;;
  release|aab)
    [[ -s android/key.properties ]] || fail 'Release signing requires android/key.properties. Use debug for a development APK.'
    prepare
    flutter analyze --no-pub
    flutter test --no-pub
    python3 -m unittest discover -s test/tools -p 'test_*.py'
    if [[ "$1" == aab ]]; then
      flutter build appbundle --release --no-pub
    else
      flutter build apk --release --split-per-abi --no-pub --obfuscate --split-debug-info=build/app/outputs/symbols
      for abi in arm64-v8a armeabi-v7a x86_64; do
        mv "build/app/outputs/flutter-apk/app-$abi-release.apk" "build/app/outputs/flutter-apk/teapod-stream-$abi.apk"
      done
      (cd android && ./gradlew :app:testReleaseUnitTest)
      # A local release may come from a dirty tree; only publishing (CI) requires a clean one.
      python3 tools/verify_release_apks.py --source-sha "$(git rev-parse HEAD)" --require-release-signature
      [[ -z "$(git status --porcelain)" ]] \
        || echo 'Note: built from uncommitted changes — fine locally, not publishable.' >&2
    fi
    ;;
  run|run-release)
    prepare
    if [[ "$1" == run ]]; then flutter run --debug --no-pub; else flutter run --release --no-pub; fi
    ;;
  push|pushpre)
    command -v gh >/dev/null || fail 'GitHub CLI is required'
    [[ -z "$(git status --porcelain)" ]] || fail 'Commit all source changes before requesting a CI release'
    branch="$(git branch --show-current)"
    [[ -n "$branch" ]] || fail 'Check out a branch containing the source commit'
    source_sha="$(git rev-parse HEAD)"
    remote_sha="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
    [[ "$remote_sha" == "$source_sha" ]] || fail 'Push the source commit before requesting its CI build'
    prerelease=false
    [[ "$1" == pushpre ]] && prerelease=true
    gh workflow run build.yml --ref "$branch" -f publish_release=true -f prerelease="$prerelease" -f source_sha="$source_sha"
    ;;
  clean) setup_environment; flutter clean ;;
  help|--help|-h) echo 'Usage: ./build.sh {binaries|debug|release|aab|run|run-release|push|pushpre|clean}' ;;
  *) fail 'Unknown build command' ;;
esac
