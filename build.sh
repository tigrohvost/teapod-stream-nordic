#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

fail() { echo "$*" >&2; exit 1; }
command -v python3 >/dev/null || fail 'Python 3 is required'

setup_environment() {
  if [[ -z "${JAVA_HOME:-}" ]]; then
    if [[ "$(uname -s)" == Darwin && -x /usr/libexec/java_home ]]; then
      JAVA_HOME="$(/usr/libexec/java_home -v 17)"
    elif command -v java >/dev/null; then
      JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    else fail 'Set JAVA_HOME to a JDK 17 installation'; fi
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
  [[ -x "$JAVA_HOME/bin/java" && -d "$ANDROID_HOME/platforms" ]] || fail 'JDK or Android SDK is missing'
  command -v flutter >/dev/null || fail 'Add the locked Flutter SDK to PATH'
  python3 -c 'import json,os,subprocess,re; lock=json.load(open("dependencies.lock.json")); out=subprocess.check_output([os.environ["JAVA_HOME"]+"/bin/java","-version"],stderr=subprocess.STDOUT,text=True); assert re.search(r"version \""+lock["toolchain"]["java"]+r"[.\"]",out), "JDK does not match dependencies.lock.json"'
  flutter --version --machine | python3 -c 'import json,sys; v=json.load(sys.stdin); lock=json.load(open("dependencies.lock.json")); assert v["frameworkVersion"] == lock["toolchain"]["flutter"], "Flutter SDK does not match dependencies.lock.json"'
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
      python3 tools/verify_release_apks.py --source-sha "$(git rev-parse HEAD)" --require-release-signature
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
