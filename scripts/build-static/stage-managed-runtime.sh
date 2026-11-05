#!/bin/bash
# Stage the assets required by the existing Darwin managed-process boundary.
set -euo pipefail

fail() { echo "Managed runtime packaging failed: $1" >&2; exit 1; }
[ "$#" -eq 3 ] || fail invalid_arguments
root=$1
output=$2
platform=$3
case "$platform" in macos-aarch64|macos-x86_64) ;; *) fail unsupported_platform ;; esac
cli="$output/magic-cli"
broker="$root/scripts/metis-stdio-broker.mjs"
gate="$root/target/native/metis-exec-gate-v1"
for input in "$cli" "$broker" "$gate"; do
    [ -f "$input" ] && [ ! -L "$input" ] || fail invalid_input
 done
[ -x "$cli" ] && [ -x "$gate" ] || fail nonexecutable_input
mode=$(stat -f '%Lp' "$gate") || fail invalid_gate_mode
(( (8#$mode & 8#22) == 0 )) || fail insecure_gate_mode
for source in "$root/src/process/managed_exec_gate.c" "$root/build.cj"; do
    [ -f "$source" ] && [ ! -L "$source" ] || fail missing_build_source
    [ ! "$gate" -ot "$source" ] || fail stale_gate
 done
[ -d "$output" ] && [ ! -L "$output" ] || fail invalid_output
stage=$(mktemp -d "$output/.managed-runtime.XXXXXX") || fail stage_creation
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/runtime/bin" "$stage/runtime/scripts" "$stage/runtime/libexec"
cp "$cli" "$stage/runtime/bin/magic-cli"
cp "$broker" "$stage/runtime/scripts/metis-stdio-broker.mjs"
cp "$gate" "$stage/runtime/libexec/metis-exec-gate-v1"
chmod 755 "$stage/runtime/bin/magic-cli" "$stage/runtime/libexec/metis-exec-gate-v1"
chmod 644 "$stage/runtime/scripts/metis-stdio-broker.mjs"
for pair in bin/magic-cli scripts/metis-stdio-broker.mjs libexec/metis-exec-gate-v1; do
    case "$pair" in
        bin/*) original="$cli" ;;
        scripts/*) original="$broker" ;;
        libexec/*) original="$gate" ;;
    esac
    cmp -s "$original" "$stage/runtime/$pair" || fail staging_changed_input
 done
tar -czf "$stage/runtime.tar.gz" -C "$stage/runtime" bin scripts libexec
mv -f "$stage/runtime.tar.gz" "$output/magic-cli-$platform-runtime.tar.gz"
echo "Managed Darwin runtime archive created."
