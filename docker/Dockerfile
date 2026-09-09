FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
COPY ../xmppx ../xmppx
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o bin/server

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates openssl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /runtime/ /
COPY --from=build /app/bin/server /app/server
COPY config /app/config
COPY lib/src/db/schema.sql /app/lib/src/db/schema.sql
EXPOSE 8443
ENTRYPOINT ["/app/server", "--config", "/app/config/rainbow-stub.yaml"]
