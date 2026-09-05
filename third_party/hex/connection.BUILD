load("@rules_elixir//:mix_app.bzl", "mix_app")
load("@firstmate_port//build:hex_compile_env.bzl", "HEX_COMPILE_ENV_CONFIG")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "sources",
    srcs = glob(
        ["**/*"],
        allow_empty = True,
    ),
)

mix_app(
    name = "erlang_app",
    app_name = "connection",
    srcs = [":sources"],
    hdrs = glob(
        ["include/**/*.hrl"],
        allow_empty = True,
    ),
    extra_config = HEX_COMPILE_ENV_CONFIG,
    deps = [
        "@rules_elixir//elixir",
    ],
)
