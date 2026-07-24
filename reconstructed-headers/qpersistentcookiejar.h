/* qpersistentcookiejar.h — reconstructed declaration for the Atlas WPE BrowserServer build.
 * DEAD in the WPE port: m_cookieJar is never allocated (the `new QPersistentCookieJar(...)` is commented
 * out — "cookies owned by WebKit network process"), so every call is guarded `if (m_cookieJar) ...` and
 * the type is never instantiated. Only method DECLARATIONS are needed (compile + link; no vtable is
 * referenced). Methods below are exactly those BrowserServer.cpp calls. Replace with the upstream Palm
 * header if the Qt cookie path is revived. */
#ifndef QPERSISTENTCOOKIEJAR_H
#define QPERSISTENTCOOKIEJAR_H
#include <QtNetwork/QNetworkCookieJar>
#include <QtCore/QString>
class QNetworkAccessManager;
class QPersistentCookieJar : public QNetworkCookieJar {
public:
    QPersistentCookieJar(QNetworkAccessManager* manager, const QString& name);
    virtual void clearCookies();
    virtual void enableCookies(bool enable);
};
#endif
