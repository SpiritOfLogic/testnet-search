package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/agent-testnet/testnet-search/crawler"
	"github.com/agent-testnet/testnet-search/index"
	"github.com/agent-testnet/testnet-search/server"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: testnet-search <serve|crawl>")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "serve":
		runServe(os.Args[2:])
	case "crawl":
		runCrawl(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\nUsage: testnet-search <serve|crawl>\n", os.Args[1])
		os.Exit(1)
	}
}

func runServe(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	certDir := fs.String("cert-dir", envOr("CERT_DIR", "/etc/testnet/certs"), "directory containing cert.pem, key.pem, ca.pem")
	listenAddr := fs.String("listen", envOr("LISTEN_ADDR", ":443"), "HTTPS listen address")
	dataDir := fs.String("data-dir", envOr("DATA_DIR", "/var/lib/testnet-search"), "directory for SQLite database")
	fs.Parse(args)

	tlsCert, err := tls.LoadX509KeyPair(*certDir+"/cert.pem", *certDir+"/key.pem")
	if err != nil {
		log.Fatalf("[serve] load TLS cert: %v", err)
	}
	log.Println("[serve] TLS certificates loaded")

	db, err := index.Open(*dataDir)
	if err != nil {
		log.Fatalf("[serve] open index: %v", err)
	}
	idx := index.New(db)
	defer idx.Close()

	srv, err := server.New(idx, tlsCert, *listenAddr)
	if err != nil {
		log.Fatalf("[serve] create server: %v", err)
	}

	go func() {
		if err := srv.Start(); err != nil {
			log.Fatalf("[serve] %v", err)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	log.Printf("[serve] received %v, shutting down...", sig)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("[serve] shutdown error: %v", err)
	}
	log.Println("[serve] shutdown complete")
}

func runCrawl(args []string) {
	fs := flag.NewFlagSet("crawl", flag.ExitOnError)
	certDir := fs.String("cert-dir", envOr("CERT_DIR", "/etc/testnet/certs"), "directory containing ca.pem")
	dataDir := fs.String("data-dir", envOr("DATA_DIR", "/var/lib/testnet-search"), "directory for SQLite database")
	dnsIP := fs.String("dns-ip", envOr("DNS_IP", "10.100.0.1"), "testnet DNS address")
	seedFile := fs.String("seed-file", envOr("SEED_FILE", "/var/lib/testnet-search/seeds.txt"), "file with one domain per line")
	crawlDelay := fs.Duration("crawl-delay", parseDurationOr("CRAWL_DELAY", 500*time.Millisecond), "delay between HTTP requests")
	maxPages := fs.Int("max-pages-per-domain", parseIntOr("MAX_PAGES", 200), "max pages to crawl per domain")
	continuous := fs.Bool("continuous", false, "run continuously with periodic re-crawls")
	crawlInterval := fs.Duration("crawl-interval", parseDurationOr("CRAWL_INTERVAL", 1*time.Hour), "time between full re-crawls (continuous mode)")
	domainPollInterval := fs.Duration("domain-poll-interval", parseDurationOr("DOMAIN_POLL_INTERVAL", 5*time.Minute), "time between seed file re-reads (continuous mode)")
	fs.Parse(args)

	caCert, err := os.ReadFile(*certDir + "/ca.pem")
	if err != nil {
		log.Fatalf("[crawl] read CA cert: %v", err)
	}
	log.Println("[crawl] CA certificate loaded")

	db, err := index.Open(*dataDir)
	if err != nil {
		log.Fatalf("[crawl] open index: %v", err)
	}
	idx := index.New(db)
	defer idx.Close()

	c := crawler.New(crawler.Config{
		DNSIP:      *dnsIP,
		CACert:     caCert,
		CrawlDelay: *crawlDelay,
		MaxPages:   *maxPages,
		SeedFile:   *seedFile,
		Index:      idx,
	})

	// Run initial crawl.
	log.Println("[crawl] starting initial crawl...")
	if err := c.DiscoverAndCrawl(); err != nil {
		log.Printf("[crawl] initial crawl error: %v", err)
	} else {
		log.Println("[crawl] initial crawl complete")
	}

	if !*continuous {
		log.Println("[crawl] one-shot mode, exiting")
		return
	}

	// Continuous mode: periodic re-crawl and seed refresh.
	domainTicker := time.NewTicker(*domainPollInterval)
	crawlTicker := time.NewTicker(*crawlInterval)
	defer domainTicker.Stop()
	defer crawlTicker.Stop()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	for {
		select {
		case <-domainTicker.C:
			log.Println("[crawl] refreshing domain list from seed file...")
			if err := c.RefreshDomains(); err != nil {
				log.Printf("[crawl] domain refresh error: %v", err)
			}
		case <-crawlTicker.C:
			log.Println("[crawl] starting scheduled re-crawl...")
			if err := c.DiscoverAndCrawl(); err != nil {
				log.Printf("[crawl] re-crawl error: %v", err)
			} else {
				log.Println("[crawl] scheduled re-crawl complete")
			}
		case sig := <-sigCh:
			log.Printf("[crawl] received %v, shutting down...", sig)
			return
		}
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func parseDurationOr(envKey string, fallback time.Duration) time.Duration {
	if v := os.Getenv(envKey); v != "" {
		d, err := time.ParseDuration(v)
		if err == nil {
			return d
		}
	}
	return fallback
}

func parseIntOr(envKey string, fallback int) int {
	if v := os.Getenv(envKey); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return fallback
}
