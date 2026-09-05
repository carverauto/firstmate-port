# Remote-exec platform. Override the container-image via .bazelrc.remote
# for a private executor fleet. The public BuildBuddy image is a generic default.
platform(
    name = "rbe_platform",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
        "@erlang_config//:erlang_internal",
        "@elixir_config//:elixir_internal",
    ],
    exec_properties = {
        "OSFamily": "Linux",
        "Arch": "amd64",
        "dockerNetwork": "host",
        "container-image": "docker://gcr.io/flame-public/rbe-ubuntu24-04:latest",
    },
    visibility = ["//visibility:public"],
)
