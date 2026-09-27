#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: install-shfmt.sh DESTINATION}"
version=3.14.1
case "$(uname -m)" in
x86_64)
    architecture=amd64
    expected=76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf
    ;;
aarch64 | arm64)
    architecture=arm64
    expected=5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489
    ;;
*)
    echo 'Unsupported architecture for shfmt.' >&2
    exit 1
    ;;
esac
temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT
curl -fsSL "https://github.com/mvdan/sh/releases/download/v${version}/shfmt_v${version}_linux_${architecture}" -o "$temporary"
printf '%s  %s\n' "$expected" "$temporary" | sha256sum -c -
install -m 0755 "$temporary" "$destination"
