"""Compile-time application config that Hex dependencies must be compiled against."""

HEX_COMPILE_ENV_CONFIG = [
    "config :ash, include_embedded_source_by_default?: false",
]
