#!/bin/bash
# Checks the float → integer conversion of the bit-perfect output bit for bit (plain JDK, no Android).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../../clients/app/third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/PcmConvert.java"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
javac -d "$out" "$src" "$here/PcmConvertCheck.java"
java -cp "$out" com.ryanheise.just_audio.PcmConvertCheck
