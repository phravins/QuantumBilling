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

# Compile assets
RUN mix assets.deploy

# Compile app
RUN mix compile

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
RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libssl-dev libncurses5-dev locales ca-certificates \
  chromium fonts-liberation fonts-dejavu-core \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

ENV PDF_CHROME_PATH="/usr/bin/chromium"

# Set the locale
RUN seed-locale en_US.UTF-8 || true

WORKDIR /app
RUN chown nobody /app

# set execution env
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/quantum_billing ./

USER nobody

EXPOSE 4000

CMD ["bin/quantum_billing", "start"]
