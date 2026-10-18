# syntax=docker/dockerfile:1
# Go HTTP service for ECS/Fargate, App Runner, EKS or EC2.
# Build:  docker build -t go-app .            (add --platform linux/arm64 for Graviton)
# Run:    docker run -p 8080:8080 go-app

# --- build -------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/go-app .

# --- runtime -----------------------------------------------------------------
# Distroless: no shell, so the binary probes itself for HEALTHCHECK.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/go-app /go-app
ENV PORT=8080
EXPOSE 8080
USER nonroot:nonroot

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["/go-app", "-healthcheck"]

ENTRYPOINT ["/go-app"]
