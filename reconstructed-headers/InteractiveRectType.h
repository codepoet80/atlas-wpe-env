/* InteractiveRectType.h — reconstructed for the Atlas WPE BrowserServer build.
 *
 * Canonical webOS type, originally provided by the Palm QtWebKit fork's public headers.
 * Definition is authoritative and unambiguous (identical to the inline copy in
 * isis-project/BrowserAdapter's BrowserAdapter.h, which carries the note
 * "TODO: We should get this from the webkit headers"). The WPE-port BrowserPage inherits the
 * #include from the original BrowserPage.h prefix but does not itself use the type.
 * Replace with the upstream header if/when the webkit-fork source is added to the build.
 */
#ifndef INTERACTIVE_RECT_TYPE_H
#define INTERACTIVE_RECT_TYPE_H

enum InteractiveRectType {
    InteractiveRectDefault,
    InteractiveRectPlugin   /* interactive rect is a plugin rect */
};

#endif /* INTERACTIVE_RECT_TYPE_H */
