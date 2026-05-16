load("@rules_cc//cc:defs.bzl", "cc_library")

# Glaze is header-only — all serialisation lives in templates instantiated by
# callers (`glaze/glaze.hpp` umbrella header).

cc_library(
    name = "glaze",
    hdrs = glob([
        "include/glaze/**/*.hpp",
    ]),
    includes = ["include"],
    strip_include_prefix = "include",
    visibility = ["//visibility:public"],
)
