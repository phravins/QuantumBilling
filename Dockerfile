# ==============================================================================
# 1. Build Stage
# ==============================================================================
FROM hexpm/elixir:1.17.3-erlang-27.1.2-alpine-3.20.3 AS build

# Install build dependencies
RUN apk add --no-cache build-base git curl

WORKDIR /app

ENV MIX_ENV=prod

# Install Hex and Rebar build tools
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency specifications
COPY mix.exs mix.lock ./

# Fetch production dependencies
RUN mix deps.get --only prod

# Copy configuration files
COPY config config

# Compile dependencies
RUN mix deps.compile

# Copy static assets and source code
COPY priv priv
COPY assets assets
COPY lib lib

# Build assets and generate digest
RUN mix assets.deploy

# Compile application and assemble OTP release
RUN mix compile
RUN mix release

# ==============================================================================
# 2. Runtime Stage
# ==============================================================================
FROM alpine:3.20.3 AS runner

# Install essential runtime libraries
RUN apk add --no-cache libstdc++ openssl ncurses-libs curl

WORKDIR /app

# Run as non-root user
RUN addgroup -S app && adduser -S -G app app

# Copy release and entrypoint from build
COPY --from=build --chown=app:app /app/_build/prod/rel/quantum_billing ./
COPY --chown=app:app entrypoint.sh ./
RUN chmod +x entrypoint.sh

USER app

EXPOSE 4000

ENV HOME=/app
ENV PORT=4000
ENV PHX_SERVER=true

ENTRYPOINT ["/app/entrypoint.sh"]
