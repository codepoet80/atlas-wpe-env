// WPE port shim for <QtWebKit/qwebsettings.h>.
//
// WHY THIS EXISTS
// ---------------
// BrowserServer's Settings.cpp -> webOS::WebSettings::initWebSettings()
// (WebKitSupplemental/misc/weboswebsettings.cpp) configures the QtWebKit GLOBAL QWebSettings object.
// The Atlas engine is WPE WebKit; there is no QtWebKit engine in the process and no libQtWebKit is
// linked, so every one of those calls is meaningless here — the real settings are applied to
// WebKitSettings in BrowserPageWPE.
//
// Two problems make the upstream header unusable for this build:
//   1. setPluginSupplementalPath() and the FullScreenEnabled attribute are PALM EXTENSIONS to
//      QtWebKit. Stock QtWebKit (Debian libqtwebkit-dev 2.3.4) does not have them, so
//      weboswebsettings.cpp does not compile against it.
//   2. Even if it compiled, linking it would drag in libQtWebKit, which the WPE port does not ship.
//
// So this shim provides a QWebSettings whose setters are inline no-ops. weboswebsettings.cpp then
// compiles unchanged, initWebSettings() becomes a harmless no-op, and — the part that actually
// matters — initSettings() and stringToBytes() from the SAME upstream file are built and linked
// correctly. Those two are NOT optional: InitSettings() is called from main(), and before this file
// existed the whole translation unit was simply never compiled, so the call landed on address 0 and
// BrowserServer SIGSEGV'd on startup (blx 0 in InitSettings) before writing a line of log.
//
// This shim is placed FIRST on the include path for that one source file only (see
// build-browserserver-atlas.sh); everything else still sees the real Qt headers.
//
// Remove this once the upstream de-QtWebKit'ing of Settings/hit-test is finished.

#ifndef ATLAS_WPE_SHIM_QWEBSETTINGS_H
#define ATLAS_WPE_SHIM_QWEBSETTINGS_H

#include <QtCore/QString>
#include <QtCore/QtGlobal>

class QWebSettings {
public:
    enum WebAttribute {
        AutoLoadImages,
        JavascriptEnabled,
        PluginsEnabled,
        PrivateBrowsingEnabled,
        JavascriptCanOpenWindows,
        JavascriptCanCloseWindows,
        JavascriptCanAccessClipboard,
        DeveloperExtrasEnabled,
        SpatialNavigationEnabled,
        LinksIncludedInFocusChain,
        ZoomTextOnly,
        PrintElementBackgrounds,
        OfflineStorageDatabaseEnabled,
        OfflineWebApplicationCacheEnabled,
        LocalStorageEnabled,
        LocalContentCanAccessRemoteUrls,
        LocalContentCanAccessFileUrls,
        XSSAuditingEnabled,
        AcceleratedCompositingEnabled,
        WebGLEnabled,
        TiledBackingStoreEnabled,
        FrameFlatteningEnabled,
        SiteSpecificQuirksEnabled,
        DnsPrefetchEnabled,
        FullScreenEnabled          // Palm extension
    };

    static QWebSettings* globalSettings()
    {
        static QWebSettings instance;
        return &instance;
    }

    void setAttribute(WebAttribute, bool) {}
    void setIconDatabasePath(const QString&) {}
    void setOfflineStoragePath(const QString&) {}
    void setOfflineWebApplicationCachePath(const QString&) {}
    void setLocalStoragePath(const QString&) {}
    void setPluginSupplementalPath(const QString&) {}          // Palm extension
    void setMaximumPagesInCache(int) {}
    void setObjectCacheCapacities(int, int, int) {}
    void setOfflineStorageDefaultQuota(qint64) {}
    void setOfflineWebApplicationCacheQuota(qint64) {}
};

#endif // ATLAS_WPE_SHIM_QWEBSETTINGS_H
