FROM golang:1.24-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/discord-inbound ./cmd/discord-inbound
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /discord-inbound ./cmd/discord-inbound

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /discord-inbound /discord-inbound
USER nonroot
ENTRYPOINT ["/discord-inbound"]
