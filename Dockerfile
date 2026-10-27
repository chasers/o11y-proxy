ARG ELIXIR_VERSION=1.18.5
ARG OTP_VERSION=27.3.4.16
ARG DEBIAN_VERSION=bookworm-20260824-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod \
    O11Y_PROXY_SKIP_BURRITO=1 \
    ERL_FLAGS="+JPperf true"

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY priv priv
COPY lib lib
RUN mix release --overwrite

FROM debian:${DEBIAN_VERSION}

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libncurses6 libstdc++6 openssl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 o11y \
 && useradd --uid 1000 --gid 1000 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin o11y

COPY --from=build /src/_build/prod/rel/o11y_proxy /app

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/tmp \
    RELEASE_TMP=/tmp \
    RELEASE_DISTRIBUTION=none \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump \
    O11Y_PROXY_CONFIG=/etc/o11y-proxy/o11y.yaml

WORKDIR /tmp
USER 1000:1000
EXPOSE 4000

ENTRYPOINT ["/app/bin/o11y_proxy"]
CMD ["start"]
