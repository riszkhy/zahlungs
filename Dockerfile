# ---- Build stage -----------------------------------------------------------
# Official Docker-library image (Debian bookworm based).
FROM elixir:1.18-otp-27 AS builder

# Node is needed to install the JS deps (alpinejs, daisyui, topbar) that
# esbuild/tailwind bundle during `mix assets.deploy`.
RUN apt-get update -y && \
    apt-get install -y build-essential git nodejs npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install and compile deps first so they are cached independently of app code.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# JS deps for the asset bundle.
COPY assets/package.json assets/yarn.lock* assets/
RUN npm install --prefix assets

# App code + assets.
COPY priv priv
COPY lib lib
COPY assets assets
RUN mix assets.deploy
RUN mix compile

# Runtime config + release overlays are picked up by `mix release`.
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ---- Run stage --------------------------------------------------------------
FROM debian:bookworm-slim AS runner

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/zahlungs ./
RUN chmod +x /app/bin/*

USER nobody

# Required env at runtime: DATABASE_URL, SECRET_KEY_BASE.
# Recommended: PHX_HOST, PORT (default 4000), FORCE_SSL (behind TLS proxy).
EXPOSE 4000

# Run migrations then start the server. For strict separation, run
# `bin/migrate` as a deploy step instead and change CMD to bin/server only.
CMD ["sh", "-c", "/app/bin/migrate && /app/bin/server"]
