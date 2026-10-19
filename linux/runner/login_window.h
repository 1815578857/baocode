#ifndef RUNNER_LOGIN_WINDOW_H_
#define RUNNER_LOGIN_WINDOW_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The channel build's login window (lib/channel/account/; the macOS app
// answers the same in LoginWindow.swift), over `baocode/login_window`: the
// user's channel's account site in a WebKitGTK view of its own, ephemeral
// (its cookies and storage gone once it closes).
//
//   open (url, title)   opens it, in place of one open; an error where the
//                       app was built without WebKitGTK (webkit2gtk-4.1)
//   evaluate (script)   the string the script comes to, or null
//   cookies (url)       the cookies it has for the url, HttpOnly ones too
//   close               closes it
//
// and tells Flutter `closed` once it has, however it did.
void login_window_register(FlBinaryMessenger* messenger, GtkWindow* owner);

#endif  // RUNNER_LOGIN_WINDOW_H_
