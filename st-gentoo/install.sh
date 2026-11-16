#!/usr/bin/env bash
# Install the patched st (0.9.3 + "xresources with signal reloading") through
# Gentoo's package manager, using a tiny local overlay. Run as root.
set -euo pipefail

OVERLAY=/usr/local/portage
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. local overlay skeleton (once)
if [[ ! -f "$OVERLAY/profiles/repo_name" ]]; then
    mkdir -p "$OVERLAY/metadata" "$OVERLAY/profiles"
    echo "local-overlay" > "$OVERLAY/profiles/repo_name"
    printf 'masters = gentoo\n' > "$OVERLAY/metadata/layout.conf"
    mkdir -p /etc/portage/repos.conf
    printf '[local-overlay]\nlocation = %s\nmasters = gentoo\nauto-sync = no\n' "$OVERLAY" \
        > /etc/portage/repos.conf/local-overlay.conf
fi

# 2. package files
mkdir -p "$OVERLAY/x11-terms/st/files"
cp "$SRC"/st-0.9.3-r1.ebuild "$OVERLAY/x11-terms/st/"
cp "$SRC"/files/st-xresources-signal.diff "$OVERLAY/x11-terms/st/files/"
ebuild "$OVERLAY/x11-terms/st/st-0.9.3-r1.ebuild" manifest

# 3. savedconfig (savedconfig USE flag restores this config.h at build time)
mkdir -p /etc/portage/package.use /etc/portage/savedconfig/x11-terms/st-0.9.3
echo 'x11-terms/st savedconfig' > /etc/portage/package.use/st-local
cp "$SRC"/config.h /etc/portage/savedconfig/x11-terms/st-0.9.3/config.h

# 4. build
emerge -v x11-terms/st

echo
echo "st is now /usr/bin/st with the live-reload patch;"
echo "toggle-theme.sh switches its palette (xrdb -merge + SIGUSR1)."