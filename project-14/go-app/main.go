package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Same name and unit as Spring Boot's Micrometer timer, so one dashboard query covers both.
var requestDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
	Name: "http_server_requests_seconds",
	Help: "HTTP request latency by method and status code.",
}, []string{"method", "code"})

func init() {
	prometheus.MustRegister(requestDuration)
}

func main() {
	healthcheck := flag.Bool("healthcheck", false, "probe the local /health endpoint and exit (for Docker HEALTHCHECK)")
	flag.Parse()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	if *healthcheck {
		os.Exit(probe("http://127.0.0.1:" + port + "/health"))
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	var ready atomic.Bool
	// HOST empty = all interfaces (containers); 127.0.0.1 behind a local reverse proxy.
	srv := &http.Server{
		Addr:              os.Getenv("HOST") + ":" + port,
		Handler:           promhttp.InstrumentHandlerDuration(requestDuration, newMux(&ready)),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		logger.Info("listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()
	ready.Store(true)

	// ECS sends SIGTERM on task stop: fail readiness, then drain in-flight requests.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	ready.Store(false)
	logger.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown", "err", err)
	}
}

func newMux(ready *atomic.Bool) *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"app": "go-app", "message": "Hello from Go"})
	})

	// Liveness: the process is serving requests.
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
	})

	// Readiness: false while starting up or draining on shutdown.
	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		if !ready.Load() {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "DOWN"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
	})

	// Prometheus metrics (Go runtime, process, requests). Behind Caddy on the AMIs this path is
	// blocked; Alloy scrapes it on loopback.
	mux.Handle("GET /metrics", promhttp.Handler())

	return mux
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func probe(url string) int {
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintln(os.Stderr, "unhealthy:", resp.Status)
		return 1
	}
	return 0
}
