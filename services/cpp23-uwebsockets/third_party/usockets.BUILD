load("@rules_cc//cc:defs.bzl", "cc_library")

# LIBUS_NO_SSL: the gateway speaks cleartext WS on the ingress side and
# cleartext h2c to the inference server, so we don't link OpenSSL.

cc_library(
    name = "usockets",
    srcs = glob(
        [
            "src/*.c",
            "src/eventing/*.c",
            "src/internal/**/*.h",
        ],
        exclude = [
            "src/crypto/*",
        ],
    ),
    hdrs = glob([
        "src/*.h",
    ]),
    copts = [
        "-DLIBUS_NO_SSL",
        "-std=c11",
        "-O3",
        "-fno-strict-aliasing",
    ],
    defines = [
        "LIBUS_NO_SSL",
    ],
    includes = ["src"],
    strip_include_prefix = "src",
    visibility = ["//visibility:public"],
)
