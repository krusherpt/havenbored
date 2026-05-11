# syntax=docker/dockerfile:1
FROM elixir:1.19-alpine AS build

ARG MIX_ENV=prod

ENV MIX_ENV=$MIX_ENV \
    MIX_HOME=/app/.mix \
    HEX_HOME=/app/.hex \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LC_CTYPE=C.UTF-8

RUN apk add --no-cache \
    git \
    make \
    build-base \
    rust \
    cargo

WORKDIR /app
COPY --exclude=entrypoint.sh . .

 # Install hex/rebar, get dependencies.
 RUN mix deps.get --only $MIX_ENV
 RUN mix compile
 RUN mix release
FROM elixir:1.19-alpine

ENV MIX_ENV=prod \
    MIX_HOME=/app/.mix \
    HEX_HOME=/app/.hex \
    HOME=/app \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LC_CTYPE=C.UTF-8

RUN apk add --no-cache \
    ffmpeg \
    git \
    libstdc++

WORKDIR /app
COPY --from=build /app .
RUN chmod -R a+rX /app/.mix /app/.hex

COPY entrypoint.sh /app
RUN chmod a+x /app/entrypoint.sh

VOLUME ["/app/priv/static/uploads"]
EXPOSE 4000
ENTRYPOINT ["/app/entrypoint.sh"]
