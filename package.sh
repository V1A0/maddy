#!/bin/bash

# Build maddy using get.sh and copy all installation files into maddy-pkgdir-XXXXXXXXX directory.
# DO NOT RUN FROM THE SOURCE DIRECTORY. IT WILL BREAK.

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

if [ "$script_dir" = "$PWD" ]; then
    echo 'Do not run package.sh from the source directory.' >&2
    exit 1
fi

if [ "$pkgdir" = "" ]; then
    pkgdir="$PWD"/maddy-pkgdir-$(date +%s)
    rm -rf "$pkgdir"
    mkdir "$pkgdir"
fi

if [ "$PREFIX" = "" ]; then
    export PREFIX="/usr"
fi
if [ "$HOSTNAME" = "" ]; then
    export HOSTNAME=example.org
fi

export DESTDIR="$pkgdir" NO_RUN=1 SUDO=fakeroot
# shellcheck source=get.sh
. "$script_dir"/get.sh

set -euo pipefail

mkdir -p maddy-setup
cd maddy-setup/

run() {
    ensure_go_toolchain
    download_and_compile
    install_executables
    install_dist
    install_man
    install_config </dev/null
}

run
