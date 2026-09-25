# Find eligible builder image at https://hub.docker.com/_/elixir/tags
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.2
ARG DEBIAN_VERSION=bookworm-20250126-slim

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

# Compiles the app and then bundles assets: the `assets.deploy` alias runs
# `compile` first because the CSS and JS both import the colocated-hook output
# that only the LiveView compiler produces.
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image doesn't contain the full Erlang/Elixir SDK
FROM ${RUNNER_IMAGE}

# `chromium` is what prints invoice PDFs — see QuantumBillingWeb.InvoiceDoc.PDF.
# Without it the mailer falls back to attaching the HTML document, which opens
# but is not the PDF customers expect on a tax invoice. The fonts are needed
# too: a headless browser with no fonts renders every glyph as a box, including
# the rupee sign.
# `curl` is here for the container healthcheck in docker-compose.yml, which
# hits /health. Without it the compose healthcheck has nothing to run with.
RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libssl-dev libncurses5-dev locales ca-certificates curl \
  chromium fonts-liberation fonts-dejavu-core \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

ENV PDF_CHROME_PATH="/usr/bin/chromium"

# Set the locale. This used to call `seed-locale`, which is not a command on
# any Debian image — `|| true` meant the image built anyway with the C locale,
# and anything non-ASCII (the rupee sign, a client's name) came out wrong.
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

EXPOSE 4000

CMD ["bin/quantum_billing", "start"]
