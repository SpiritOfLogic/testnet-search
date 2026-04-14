package index

import (
	"database/sql"
	"fmt"
	"time"
)

// Index wraps the SQLite FTS5 database for full-text search operations.
type Index struct {
	db *sql.DB
}

// SearchResult is a single search hit returned by Search.
type SearchResult struct {
	URL     string  `json:"url"`
	Domain  string  `json:"domain"`
	Title   string  `json:"title"`
	Snippet string  `json:"snippet"`
	Rank    float64 `json:"rank"`
}

// DomainSummary is a domain entry for the browse directory.
type DomainSummary struct {
	Domain      string `json:"domain"`
	PageCount   int    `json:"page_count"`
	LastCrawled string `json:"last_crawled"`
}

// PageSummary is a page entry for the domain detail view.
type PageSummary struct {
	URL         string `json:"url"`
	Title       string `json:"title"`
	Description string `json:"description"`
}

// New creates an Index backed by the given database.
func New(db *sql.DB) *Index {
	return &Index{db: db}
}

// Upsert inserts or replaces a page in both the FTS5 table and metadata table.
func (idx *Index) Upsert(pageURL, domain, title, description, content string) error {
	tx, err := idx.db.Begin()
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	// Delete existing FTS5 row if present (FTS5 doesn't support ON CONFLICT).
	if _, err := tx.Exec(`DELETE FROM pages WHERE url = ?`, pageURL); err != nil {
		return fmt.Errorf("delete old fts row: %w", err)
	}
	if _, err := tx.Exec(
		`INSERT INTO pages (url, domain, title, description, content) VALUES (?, ?, ?, ?, ?)`,
		pageURL, domain, title, description, content,
	); err != nil {
		return fmt.Errorf("insert fts row: %w", err)
	}

	if _, err := tx.Exec(
		`INSERT OR REPLACE INTO page_meta (url, domain, title, description, crawled_at) VALUES (?, ?, ?, ?, ?)`,
		pageURL, domain, title, description, time.Now().UTC().Format(time.RFC3339),
	); err != nil {
		return fmt.Errorf("upsert meta row: %w", err)
	}

	return tx.Commit()
}

// DeleteByDomain removes all pages belonging to the given domain.
func (idx *Index) DeleteByDomain(domain string) error {
	tx, err := idx.db.Begin()
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`DELETE FROM pages WHERE domain = ?`, domain); err != nil {
		return fmt.Errorf("delete fts rows: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM page_meta WHERE domain = ?`, domain); err != nil {
		return fmt.Errorf("delete meta rows: %w", err)
	}

	return tx.Commit()
}

// Search performs a full-text search and returns ranked results with snippets.
func (idx *Index) Search(query string, page, pageSize int) ([]SearchResult, int, error) {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 10
	}
	offset := (page - 1) * pageSize

	// Count total matches.
	var total int
	err := idx.db.QueryRow(`SELECT count(*) FROM pages WHERE pages MATCH ?`, query).Scan(&total)
	if err != nil {
		return nil, 0, fmt.Errorf("count results: %w", err)
	}

	rows, err := idx.db.Query(
		`SELECT url, domain, title,
		        snippet(pages, 4, '<b>', '</b>', '...', 30) AS snippet,
		        bm25(pages) AS rank
		 FROM pages
		 WHERE pages MATCH ?
		 ORDER BY rank
		 LIMIT ? OFFSET ?`,
		query, pageSize, offset,
	)
	if err != nil {
		return nil, 0, fmt.Errorf("search query: %w", err)
	}
	defer rows.Close()

	var results []SearchResult
	for rows.Next() {
		var r SearchResult
		if err := rows.Scan(&r.URL, &r.Domain, &r.Title, &r.Snippet, &r.Rank); err != nil {
			return nil, 0, fmt.Errorf("scan row: %w", err)
		}
		results = append(results, r)
	}
	return results, total, rows.Err()
}

// ListDomains returns all indexed domains with page counts and last crawl time.
func (idx *Index) ListDomains() ([]DomainSummary, error) {
	rows, err := idx.db.Query(
		`SELECT domain, count(*) AS page_count, max(crawled_at) AS last_crawled
		 FROM page_meta
		 GROUP BY domain
		 ORDER BY domain`,
	)
	if err != nil {
		return nil, fmt.Errorf("list domains: %w", err)
	}
	defer rows.Close()

	var domains []DomainSummary
	for rows.Next() {
		var d DomainSummary
		if err := rows.Scan(&d.Domain, &d.PageCount, &d.LastCrawled); err != nil {
			return nil, fmt.Errorf("scan domain: %w", err)
		}
		domains = append(domains, d)
	}
	return domains, rows.Err()
}

// ListPagesByDomain returns all indexed pages for a specific domain.
func (idx *Index) ListPagesByDomain(domain string) ([]PageSummary, error) {
	rows, err := idx.db.Query(
		`SELECT url, title, description
		 FROM page_meta
		 WHERE domain = ?
		 ORDER BY url`,
		domain,
	)
	if err != nil {
		return nil, fmt.Errorf("list pages: %w", err)
	}
	defer rows.Close()

	var pages []PageSummary
	for rows.Next() {
		var p PageSummary
		var title, desc sql.NullString
		if err := rows.Scan(&p.URL, &title, &desc); err != nil {
			return nil, fmt.Errorf("scan page: %w", err)
		}
		p.Title = title.String
		p.Description = desc.String
		pages = append(pages, p)
	}
	return pages, rows.Err()
}

// Stats returns aggregate index statistics.
func (idx *Index) Stats() (indexedPages int, indexedDomains int, err error) {
	err = idx.db.QueryRow(
		`SELECT count(*), count(DISTINCT domain) FROM page_meta`,
	).Scan(&indexedPages, &indexedDomains)
	return
}

// Close closes the underlying database.
func (idx *Index) Close() error {
	return idx.db.Close()
}
