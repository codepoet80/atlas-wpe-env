/* webkit/webos_compat.h — reconstructed shim for the Atlas WPE BrowserServer build.
 * Palm's original provided QtWebKit build-compat glue incl. the WEBOS_PLATFORM_PLUGIN() accessor that
 * returned the Qt platform plugin. The WPE port has no Qt platform plugin, so BrowserServer::
 * initPlatformPlugin() is dead: the accessor yields null and the function returns early. Faithful to WPE
 * behaviour; restore the upstream header if QtWebKit platform integration is revived. */
#ifndef WEBOS_COMPAT_H
#define WEBOS_COMPAT_H
class QWebKitPlatformPlugin;
#define WEBOS_PLATFORM_PLUGIN() (static_cast<QWebKitPlatformPlugin*>(0))
#endif
