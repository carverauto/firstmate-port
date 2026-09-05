"""elixir_release plus the ERTS this repository ships. Pattern from serviceradar."""

load("@rules_elixir//:elixir_release.bzl", _elixir_release = "elixir_release")

SHIPPED_ERTS_OTP_ROOT = select({
    Label("//build/platforms:target_linux_arm64"): "@otp_28_1_linux_arm64//:otp_root",
    "//conditions:default": None,
})

SHIPPED_ERTS_ROOT_MARKER = select({
    Label("//build/platforms:target_linux_arm64"): "@otp_28_1_linux_arm64//:root_marker",
    "//conditions:default": None,
})

def elixir_release(**kwargs):
    return _elixir_release(**kwargs)
