# ============================================================
# Stage 1 — Builder
# ============================================================
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4.3
ARG DEBIAN_VERSION=bookworm-20250407-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

# Install Hex + Rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Copy dependency manifests first for better layer caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files before we compile deps
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy priv, lib, and assets
COPY priv priv
COPY lib lib
COPY assets assets

# Compile and deploy assets
RUN mix assets.deploy

# Compile application
RUN mix compile

# Copy runtime config last (it is evaluated at startup, not compile time)
COPY config/runtime.exs config/

# Copy release overlay scripts
COPY rel rel

# Build the release
RUN mix release

# ============================================================
# Stage 2 — Runner
# ============================================================
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && apt-get install -y \
      libstdc++6 \
      openssl \
      libncurses5 \
      locales \
      ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"

WORKDIR /app

RUN chown nobody /app

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/viche ./

USER nobody

CMD ["/app/bin/server"]

# Fly.io IPv6 networking
ENV ECTO_IPV6="true"
ENV ERL_AFLAGS="-proto_dist inet6_tcp"
