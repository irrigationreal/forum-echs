# =============================================================================
# ECHS (Elixir Codex Harness Server) - Multi-stage Docker Build
# =============================================================================

FROM hexpm/elixir:1.16.2-erlang-26.2.5-alpine-3.19 AS base

RUN apk add --no-cache git build-base

WORKDIR /app

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix local.hex --force && mix local.rebar --force

FROM base AS deps

COPY apps ./apps

RUN mix deps.get

FROM deps AS build

ENV MIX_ENV=prod

RUN mix compile
RUN mix release echs_server

FROM alpine:3.19 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/echs_server ./

ENV ECHS_BIND=0.0.0.0
ENV ECHS_PORT=4000

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:4000/healthz || exit 1

CMD ["/app/bin/echs_server", "foreground"]
