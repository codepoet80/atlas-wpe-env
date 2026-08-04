#!/bin/bash
# Build the Atlas ipk for distribution through a Preware-style FEED (e.g. WOSA Modernize).
#
# Differs from the standalone build ONLY in control.tar.gz — the engine payload is identical, so a feed
# can index these bits without repacking anything:
#   - postinst/prerm do NOT restart LunaSysMgr. Preware runs under LunaSysMgr, so restarting it mid-batch
#     kills the installer and abandons the rest of the dependency chain. The reload is declared instead as
#     PostInstallFlags/PostUpdateFlags/PostRemoveFlags = RestartLuna.
#   - Depends: the feed's OpenSSL 1.1 package (Atlas needs /usr/lib/ssl11 for HTTPS).
#     Override with FEED_DEPENDS=... for a feed that packages OpenSSL under another name.
#
# NOTE: Preware reads the restart flags from the FEED's Packages index "Source" block, not from the ipk's
# control — copy them into your stanza as well.
#
#   ./build-ipk-feed.sh        # -> atlas-browser-app/ipks/feed/org.webosports.app.atlas_<ver>_all.ipk
set -eu
exec env ATLAS_PKG_TARGET=feed "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/build-ipk-atlas.sh" "$@"
