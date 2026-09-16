import Config

# `adbc` downloads its driver at *compile* time — the bottom of its `lib/adbc.ex` reads
# this key with `Application.compile_env/3` and fetches the shared library then. Without
# it the `:duckdb` driver is simply absent at runtime, and
# `O11yProxy.Backends.S3` fails to init with a driver-not-found error rather than
# anything that points here. The library is DuckDB's own `libduckdb`, so `INSTALL httpfs`
# and the rest of the extension mechanism work normally.
config :adbc, :drivers, [:duckdb]
