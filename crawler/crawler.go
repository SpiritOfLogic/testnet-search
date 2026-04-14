package crawler

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/agent-testnet/testnet-search/index"
)

const maxBodySize = 5 * 1024 * 1024 // 5 MB

// Config holds crawler settings.
type Config struct {
	DNSIP      string
	CACert     []byte
	CrawlDelay time.Duration
	MaxPages   int
	SeedFile   string
	Index      *index.Index
}

// Crawler discovers testnet domains and crawls their pages.
type Crawler struct {
	cfg        Config
	httpClient *http.Client

	mu             sync.Mutex
	allowedDomains map[string]struct{}
	lastCrawl      time.Time
}

// New creates a Crawler with an HTTP client configured for the testnet
// (custom DNS resolver + testnet-only CA trust).
func New(cfg Config) *Crawler {
	c := &Crawler{
		cfg:            cfg,
		allowedDomains: make(map[string]struct{}),
	}
	c.httpClient = c.buildHTTPClient()
	return c
}

// LastCrawlTime returns the time the last crawl completed.
func (c *Crawler) LastCrawlTime() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastCrawl
}

// readSeeds reads the seed file and returns the list of domains.
func (c *Crawler) readSeeds() ([]string, error) {
	f, err := os.Open(c.cfg.SeedFile)
	if err != nil {
		return nil, fmt.Errorf("open seed file: %w", err)
	}
	defer f.Close()

	var domains []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line != "" && !strings.HasPrefix(line, "#") {
			domains = append(domains, line)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read seed file: %w", err)
	}
	return domains, nil
}

// DiscoverAndCrawl reads the seed file, updates the allowed set,
// removes stale domains from the index, and crawls all domains.
func (c *Crawler) DiscoverAndCrawl() error {
	seeds, err := c.readSeeds()
	if err != nil {
		return err
	}

	newAllowed := make(map[string]struct{}, len(seeds))
	for _, d := range seeds {
		newAllowed[d] = struct{}{}
	}

	c.mu.Lock()
	oldAllowed := c.allowedDomains
	c.allowedDomains = newAllowed
	c.mu.Unlock()

	for domain := range oldAllowed {
		if _, ok := newAllowed[domain]; !ok {
			log.Printf("[crawler] domain removed: %s, purging from index", domain)
			if err := c.cfg.Index.DeleteByDomain(domain); err != nil {
				log.Printf("[crawler] error purging domain %s: %v", domain, err)
			}
		}
	}

	log.Printf("[crawler] crawling %d domains", len(seeds))
	for _, domain := range seeds {
		c.crawlDomain(domain)
	}

	c.mu.Lock()
	c.lastCrawl = time.Now().UTC()
	c.mu.Unlock()

	return nil
}

// RefreshDomains re-reads the seed file and crawls any newly discovered
// domains. Does not trigger a full re-crawl of existing domains.
func (c *Crawler) RefreshDomains() error {
	seeds, err := c.readSeeds()
	if err != nil {
		return err
	}

	c.mu.Lock()
	var newDomains []string
	removedDomains := make(map[string]struct{})
	for d := range c.allowedDomains {
		removedDomains[d] = struct{}{}
	}

	for _, d := range seeds {
		delete(removedDomains, d)
		if _, ok := c.allowedDomains[d]; !ok {
			c.allowedDomains[d] = struct{}{}
			newDomains = append(newDomains, d)
		}
	}

	for d := range removedDomains {
		delete(c.allowedDomains, d)
	}
	c.mu.Unlock()

	for d := range removedDomains {
		log.Printf("[crawler] domain removed: %s, purging from index", d)
		if err := c.cfg.Index.DeleteByDomain(d); err != nil {
			log.Printf("[crawler] error purging domain %s: %v", d, err)
		}
	}

	if len(newDomains) > 0 {
		log.Printf("[crawler] discovered %d new domains, crawling", len(newDomains))
		for _, domain := range newDomains {
			c.crawlDomain(domain)
		}
	}

	return nil
}

func (c *Crawler) crawlDomain(domain string) {
	seedURL := "https://" + domain + "/"
	queue := []string{seedURL}
	visited := make(map[string]struct{})
	pageCount := 0

	log.Printf("[crawler] starting crawl of %s", domain)

	for len(queue) > 0 && pageCount < c.cfg.MaxPages {
		rawURL := queue[0]
		queue = queue[1:]

		normalized := NormalizeURL(rawURL)
		if normalized == "" {
			continue
		}
		if _, ok := visited[normalized]; ok {
			continue
		}
		visited[normalized] = struct{}{}

		body, err := c.fetch(normalized)
		if err != nil {
			log.Printf("[crawler] fetch %s: %v", normalized, err)
			continue
		}

		result := ExtractReadableText(body, normalized)
		if err := c.cfg.Index.Upsert(normalized, domain, result.Title, result.Description, result.Content); err != nil {
			log.Printf("[crawler] index upsert %s: %v", normalized, err)
		}
		pageCount++

		parsedBase, err := url.Parse(normalized)
		if err != nil {
			continue
		}
		links := ExtractLinks(body, parsedBase)

		c.mu.Lock()
		allowed := c.allowedDomains
		c.mu.Unlock()

		for _, link := range links {
			linkURL, err := url.Parse(link)
			if err != nil {
				continue
			}
			host := strings.ToLower(linkURL.Hostname())
			if _, ok := allowed[host]; !ok {
				continue
			}
			if _, ok := visited[link]; !ok {
				queue = append(queue, link)
			}
		}

		time.Sleep(c.cfg.CrawlDelay)
	}

	log.Printf("[crawler] finished %s: %d pages indexed", domain, pageCount)
}

func (c *Crawler) fetch(pageURL string) ([]byte, error) {
	resp, err := c.httpClient.Get(pageURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}

	ct := resp.Header.Get("Content-Type")
	if ct != "" && !strings.Contains(ct, "text/html") && !strings.Contains(ct, "text/plain") {
		return nil, fmt.Errorf("skipping non-HTML content-type: %s", ct)
	}

	return io.ReadAll(io.LimitReader(resp.Body, maxBodySize))
}

func (c *Crawler) buildHTTPClient() *http.Client {
	caPool := x509.NewCertPool()
	caPool.AppendCertsFromPEM(c.cfg.CACert)

	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(_ context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{Timeout: 5 * time.Second}
			return d.DialContext(context.Background(), "udp", c.cfg.DNSIP+":53")
		},
	}

	dialer := &net.Dialer{
		Timeout:  10 * time.Second,
		Resolver: resolver,
	}

	transport := &http.Transport{
		DialContext:     dialer.DialContext,
		TLSClientConfig: &tls.Config{RootCAs: caPool},
	}

	return &http.Client{
		Transport: transport,
		Timeout:   30 * time.Second,
	}
}
