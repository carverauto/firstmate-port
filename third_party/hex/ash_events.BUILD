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
    app_name = "ash_events",
    srcs = [":sources"],
    hdrs = glob(
        ["include/**/*.hrl"],
        allow_empty = True,
    ),
    extra_config = HEX_COMPILE_ENV_CONFIG,
    deps = [
        "@hex_ash//:erlang_app",
        "@hex_ash_postgres//:erlang_app",
        "@hex_bcrypt_elixir//:erlang_app",
        "@rules_elixir//elixir",
    ],
)
