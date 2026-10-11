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
//	SAAA_HOSTED             1 to offer hosted accounts to people with an invite code
//	SAAA_HOSTED_KEY_FILE    file holding the Anthropic key hosted accounts use
//	SAAA_HOSTED_BUDGET_USD  monthly allowance per hosted account (default 5)
//	SAAA_HOSTED_MODELS      models hosted accounts may use (default Haiku and Sonnet 5.5)
//
// `saaa-relay invite [-plan beta] [-uses 1] [-days 30] [-budget 5] [-note text]`
// adds an invite to the data directory and prints its code.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
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
	hosted           bool
	hostedKeyFile    string
	hostedBudgetUSD  float64
	hostedModels     []string
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
		hosted:           os.Getenv("SAAA_HOSTED") == "1",
		hostedKeyFile:    os.Getenv("SAAA_HOSTED_KEY_FILE"),
		hostedBudgetUSD:  envFloat("SAAA_HOSTED_BUDGET_USD", 5),
		hostedModels:     envList("SAAA_HOSTED_MODELS", []string{"claude-haiku-5-5", "claude-sonnet-5-5"}),
	}
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "-version" || os.Args[1] == "--version") {
		fmt.Println(version)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "invite" {
		if err := inviteCommand(loadConfig(), os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "invite:", err)
			os.Exit(1)
		}
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
	meter, err := OpenMeter(cfg.dataDir)
	if err != nil {
		return fmt.Errorf("usage: %w", err)
	}
	var hosted *HostedConfig
	if cfg.hosted {
		key, err := os.ReadFile(cfg.hostedKeyFile)
		if err != nil || !LooksLikeAnthropicKey(strings.TrimSpace(string(key))) {
			return errors.New("SAAA_HOSTED=1 needs SAAA_HOSTED_KEY_FILE naming a file with an Anthropic key")
		}
		hosted = &HostedConfig{
			APIKey:       strings.TrimSpace(string(key)),
			BudgetMicros: int64(cfg.hostedBudgetUSD * 1_000_000),
			Models:       cfg.hostedModels,
		}
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
		meter:            meter,
		hosted:           hosted,
		dataDir:          cfg.dataDir,
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
				if err := meter.FlushIfDirty(); err != nil {
					logger.Warn("usage flush failed", "error", err.Error())
				}
			}
		}
	}()

	errs := make(chan error, 1)
	go func() {
		logger.Info("saaa-relay listening", "addr", cfg.addr, "tls", cfg.tlsCert != "", "hosted", hosted != nil, "version", version)
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
	return errors.Join(store.FlushIfDirty(), meter.FlushIfDirty())
}

// inviteCommand adds one invite to the data directory and prints its code.
// The running server reads invites fresh, so no restart is needed.
func inviteCommand(cfg config, args []string) error {
	flags := flag.NewFlagSet("invite", flag.ContinueOnError)
	plan := flags.String("plan", "beta", "plan name shown to the user")
	uses := flags.Int("uses", 1, "how many accounts the code can open")
	days := flags.Int("days", 30, "days until the code expires (0 for never)")
	budget := flags.Float64("budget", 0, "monthly allowance in dollars (0 for the server default)")
	note := flags.String("note", "", "who the code is for, kept with the invite")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.dataDir, 0o700); err != nil {
		return err
	}
	code, err := CreateInvite(cfg.dataDir, *plan, int64(*budget*1_000_000), *uses,
		time.Duration(*days)*24*time.Hour, *note, time.Now())
	if err != nil {
		return err
	}
	fmt.Println(code)
	return nil
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func envFloat(name string, fallback float64) float64 {
	if value, err := strconv.ParseFloat(os.Getenv(name), 64); err == nil && value > 0 {
		return value
	}
	return fallback
}

func envList(name string, fallback []string) []string {
	var items []string
	for _, item := range strings.Split(os.Getenv(name), ",") {
		if item = strings.TrimSpace(item); item != "" {
			items = append(items, item)
		}
	}
	if len(items) == 0 {
		return fallback
	}
	return items
}

func envInt(name string, fallback int) int {
	if value, err := strconv.Atoi(os.Getenv(name)); err == nil && value > 0 {
		return value
	}
	return fallback
}
