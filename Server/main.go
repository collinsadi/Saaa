// Command saaa-relay is the Saaa server: bring-your-own Anthropic keys,
// sealed at rest, with requests streamed straight through.
//
// Configuration comes from the environment (see deploy/relay.env.example):
//
//	SAAA_ADDR               listen address (default :8443)
//	SAAA_DATA               data directory for master.key and accounts.json
//	SAAA_TLS_CERT/KEY       serve HTTPS directly with this certificate
//	SAAA_UPSTREAM           Anthropic API base (default https://api.anthropic.com)
//	SAAA_MAX_BODY_MB        largest request body (default 8)
//	SAAA_RATE_PER_MINUTE    requests per account per minute (default 240)
//	SAAA_REGISTRATION_CODE  if set, connecting a key needs this code
//	SAAA_TRUST_PROXY        1 when behind a reverse proxy that sets X-Forwarded-For
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

var version = "dev"

type config struct {
	addr             string
	dataDir          string
	tlsCert, tlsKey  string
	upstream         string
	maxBodyMB        int
	ratePerMinute    int
	registrationCode string
	trustProxy       bool
}

func loadConfig() config {
	return config{
		addr:             env("SAAA_ADDR", ":8443"),
		dataDir:          env("SAAA_DATA", "./data"),
		tlsCert:          os.Getenv("SAAA_TLS_CERT"),
		tlsKey:           os.Getenv("SAAA_TLS_KEY"),
		upstream:         env("SAAA_UPSTREAM", "https://api.anthropic.com"),
		maxBodyMB:        envInt("SAAA_MAX_BODY_MB", 8),
		ratePerMinute:    envInt("SAAA_RATE_PER_MINUTE", 240),
		registrationCode: os.Getenv("SAAA_REGISTRATION_CODE"),
		trustProxy:       os.Getenv("SAAA_TRUST_PROXY") == "1",
	}
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "-version" || os.Args[1] == "--version") {
		fmt.Println(version)
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(loadConfig(), logger); err != nil {
		logger.Error("fatal", "error", err.Error())
		os.Exit(1)
	}
}

func run(cfg config, logger *slog.Logger) error {
	if err := os.MkdirAll(cfg.dataDir, 0o700); err != nil {
		return err
	}
	master, err := LoadOrCreateMasterKey(cfg.dataDir)
	if err != nil {
		return fmt.Errorf("master key: %w", err)
	}
	keys, err := DeriveKeys(master)
	if err != nil {
		return err
	}
	store, err := OpenStore(cfg.dataDir)
	if err != nil {
		return fmt.Errorf("store: %w", err)
	}
	upstream, err := url.Parse(cfg.upstream)
	if err != nil {
		return fmt.Errorf("upstream: %w", err)
	}
	server := &Server{
		store:            store,
		keys:             keys,
		upstream:         upstream,
		client:           NewUpstreamClient(),
		maxBody:          int64(cfg.maxBodyMB) << 20,
		perAccount:       NewLimiter(cfg.ratePerMinute, cfg.ratePerMinute/4+10),
		perAddress:       NewLimiter(20, 10),
		registrationCode: cfg.registrationCode,
		trustProxy:       cfg.trustProxy,
		log:              logger,
		version:          version,
		now:              time.Now,
	}
	httpServer := &http.Server{
		Addr:              cfg.addr,
		Handler:           server.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := store.FlushIfDirty(); err != nil {
					logger.Warn("store flush failed", "error", err.Error())
				}
			}
		}
	}()

	errs := make(chan error, 1)
	go func() {
		logger.Info("saaa-relay listening", "addr", cfg.addr, "tls", cfg.tlsCert != "", "version", version)
		if cfg.tlsCert != "" {
			errs <- httpServer.ListenAndServeTLS(cfg.tlsCert, cfg.tlsKey)
		} else {
			errs <- httpServer.ListenAndServe()
		}
	}()

	select {
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		logger.Info("shutting down")
		shutdown, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		httpServer.Shutdown(shutdown)
	}
	return store.FlushIfDirty()
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func envInt(name string, fallback int) int {
	if value, err := strconv.Atoi(os.Getenv(name)); err == nil && value > 0 {
		return value
	}
	return fallback
}
