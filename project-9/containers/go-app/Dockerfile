FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN go build -o /out/go-app .

FROM alpine:3.20
COPY --from=build /out/go-app /usr/local/bin/go-app

ENV PORT=8080
EXPOSE 8080

CMD ["go-app"]
