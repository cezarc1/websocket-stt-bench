ARG GO_IMAGE=golang:1.26.3-bookworm@sha256:252599aeb51ad60b83e4d8821802068127c528c707cb7dd7afd93be057c6011c

FROM ${GO_IMAGE} AS build

WORKDIR /app/services/go-nethttp
COPY services/go-nethttp/go.mod services/go-nethttp/go.sum ./
RUN go mod download

COPY services/go-nethttp ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /usr/local/bin/stt-go-nethttp ./cmd/stt-go-nethttp

FROM debian:bookworm-20260421-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/stt-go-nethttp /usr/local/bin/stt-go-nethttp

ENV PORT=6000
EXPOSE 6000
CMD ["stt-go-nethttp"]
