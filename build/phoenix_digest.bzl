"""phoenix_digest with this repository's Phoenix on the code path."""

load("@rules_elixir//:phoenix_digest.bzl", _phoenix_digest = "phoenix_digest")

def phoenix_digest(**kwargs):
    if "deps" not in kwargs:
        kwargs["deps"] = ["@hexpm//:phoenix"]
    return _phoenix_digest(**kwargs)
