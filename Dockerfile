# Production image: an OTP release plus Chromium for invoice PDFs.
# Built and run by docker-compose.yml; see docs/deployment.md.
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.4.8
ARG DEBIAN_VERSION=bookworm-20260610-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, so a code change doesn't refetch and recompile them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config only; runtime.exs is read at boot.
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib

# Runs `compile` first: the bundles import the colocated hooks it generates.
RUN mix assets.deploy

COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# The runtime image has no Elixir SDK, only the release.
FROM ${RUNNER_IMAGE}

# Chromium prints invoice PDFs; without the fonts every glyph, the rupee sign
# included, renders as a box. curl runs the compose healthcheck.
RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl \
  chromium fonts-liberation fonts-dejavu-core \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# UTF-8 locale, or the rupee sign and non-ASCII names come out wrong.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod" \
    PDF_CHROME_PATH="/usr/bin/chromium" \
    # Outside the versioned release directory, so the volume survives upgrades.
    UPLOADS_DIR="/app/uploads" \
    # The release writes its boot config here and Chromium its profile, so the
    # root filesystem can stay read-only (compose mounts /tmp as tmpfs).
    RELEASE_TMP="/tmp" \
    HOME="/tmp"

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/quantum_billing ./

# Created as nobody, so a fresh named volume mounted here is writable.
RUN mkdir -p /app/uploads && chown nobody /app/uploads

USER nobody

EXPOSE 4000

CMD ["bin/server"]
