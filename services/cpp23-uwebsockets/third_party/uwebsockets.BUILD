load("@rules_cc//cc:defs.bzl", "cc_library")

# uWebSockets is header-only — all implementation lives in templates
# instantiated by callers (App.h / WebSocket.h).

cc_library(
    name = "uwebsockets",
    hdrs = glob(["src/*.h"]),
    defines = [
        "UWS_HTTPRESPONSE_NO_WRITEMARK",
    ],
    includes = ["src"],
    strip_include_prefix = "src",
    visibility = ["//visibility:public"],
    deps = [
        "@usockets",
    ],
)
