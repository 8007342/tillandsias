# {{NAME}}: Go on Google Cloud Run.
# Cloud Run sends requests to $PORT (8080 unless set) on 0.0.0.0, stops the
# container with SIGTERM, and keeps no files between instances.
FROM docker.io/library/golang:1.25 AS build
WORKDIR /src
COPY go.* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/server /server
ENV PORT={{PORT}}
EXPOSE {{PORT}}
USER nonroot
ENTRYPOINT ["/server"]
