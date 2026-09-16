import Config

# `adbc` downloads its driver at *compile* time — the bottom of its `lib/adbc.ex` reads
# this key with `Application.compile_env/3` and fetches the shared library then. Without
# it the `:duckdb` driver is simply absent at runtime, and
# `O11yProxy.Backends.S3` fails to init with a driver-not-found error rather than
# anything that points here. The library is DuckDB's own `libduckdb`, so `INSTALL httpfs`
# and the rest of the extension mechanism work normally.
config :adbc, :drivers, [:duckdb]

# Every log line to stderr, including OTP's own.
#
# README: "Results are JSON on stdout. Notes and errors go to stderr, so `| jq` stays
# clean." Our code already honours that, but the default logger handler writes to
# standard_io, so anything OTP logs on its own account lands in the middle of the JSON.
# `net_kernel` does exactly that when distribution cannot start — a host with no epmd gets
#
#     [notice] Protocol 'inet_tcp': register/listen error: econnrefused
#     {"sources":[]}
#
# on stdout, and `| jq` fails. Found by the release pipeline's CLI smoke test, which had
# been masked for as long as an earlier step happened to leave a server (and so an epmd)
# running.
config :logger, :default_handler, config: %{type: :standard_error}
