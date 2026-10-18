# Find eligible builder image at https://hub.docker.com/_/elixir/tags
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.4.8
ARG DEBIAN_VERSION=bookworm-20260610-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build env
ENV MIX_ENV="prod"

# install dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before compiling dependencies
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib

# Runs `compile` first: the bundles import the colocated hooks it generates.
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image doesn't contain the full Erlang/Elixir SDK
FROM ${RUNNER_IMAGE}

# chromium prints invoice PDFs; without the fonts every glyph, the rupee sign
# included, renders as a box. curl runs the compose healthcheck.
RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libssl-dev libncurses5-dev locales ca-certificates curl \
  chromium fonts-liberation fonts-dejavu-core \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

ENV PDF_CHROME_PATH="/usr/bin/chromium"

# UTF-8 locale, or the rupee sign and non-ASCII names come out wrong.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# set execution env
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/quantum_billing ./

USER nobody

# Created as nobody so the uploads volume mounted here is writable.
RUN for d in /app/lib/quantum_billing-*/priv/static; do mkdir -p "$d/uploads"; done

EXPOSE 4000

CMD ["bin/server"]
