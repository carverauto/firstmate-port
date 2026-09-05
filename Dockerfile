FROM hexpm/elixir:1.19.5-erlang-28.1-debian-bookworm-20250908 AS build
ENV MIX_ENV=prod
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git build-essential ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY priv priv
COPY lib lib
COPY assets assets
# Compile first: the :phoenix_live_view compiler emits
# _build/prod/phoenix-colocated/<app>/index.js, which esbuild resolves via
# NODE_PATH. assets.deploy before compile fails with
# 'Could not resolve "phoenix-colocated/..."'.
RUN mix compile && mix assets.deploy && mix release

FROM debian:bookworm-slim AS app
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --uid 1000 app
WORKDIR /app
COPY --from=build --chown=app:app /app/_build/prod/rel/firstmate_port ./
USER 1000
ENV PHX_SERVER=true PORT=4000
EXPOSE 4000
CMD ["sh", "-c", "bin/firstmate_port eval 'FirstmatePort.Release.migrate()' && exec bin/firstmate_port start"]
