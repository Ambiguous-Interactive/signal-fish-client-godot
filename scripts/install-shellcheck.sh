#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: install-shellcheck.sh DESTINATION}"
version=0.11.0
case "$(uname -m)" in
x86_64)
    architecture=x86_64
    expected=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ;;
aarch64 | arm64)
    architecture=aarch64
    expected=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    ;;
*)
    echo 'Unsupported architecture for ShellCheck.' >&2
    exit 1
    ;;
esac
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
archive="${temporary}/shellcheck.tar.xz"
curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${version}/shellcheck-v${version}.linux.${architecture}.tar.xz" -o "$archive"
printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -
tar -xJf "$archive" -C "$temporary" "shellcheck-v${version}/shellcheck"
install -m 0755 "${temporary}/shellcheck-v${version}/shellcheck" "$destination"
