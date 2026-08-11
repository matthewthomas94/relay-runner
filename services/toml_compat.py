"""Use the stdlib TOML reader when available, with Python 3.10 parity."""

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10
    import tomli as tomllib

__all__ = ["tomllib"]
