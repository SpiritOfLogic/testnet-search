package server

import (
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/agent-testnet/testnet-search/index"
)

const defaultPageSize = 10

type handlers struct {
	idx       *index.Index
	templates *template.Template
}

// --- HTML handlers ---

func (h *handlers) handleHome(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if err := h.templates.ExecuteTemplate(w, "home.html", nil); err != nil {
		log.Printf("[server] render home: %v", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
	}
}

func (h *handlers) handleSearch(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	page := parseIntParam(r, "page", 1)
	lucky := r.URL.Query().Get("lucky") == "1"

	results, total, err := h.idx.Search(query, page, defaultPageSize)
	if err != nil {
		log.Printf("[server] search error: %v", err)
		http.Error(w, "Search error", http.StatusInternalServerError)
		return
	}

	if lucky && len(results) > 0 {
		http.Redirect(w, r, results[0].URL, http.StatusFound)
		return
	}

	totalPages := (total + defaultPageSize - 1) / defaultPageSize
	data := struct {
		Query        string
		QueryEscaped string
		Results      []resultView
		Total        int
		Page         int
		HasPrev      bool
		HasNext      bool
		PrevPage     int
		NextPage     int
	}{
		Query:        query,
		QueryEscaped: url.QueryEscape(query),
		Results:      toResultViews(results),
		Total:        total,
		Page:         page,
		HasPrev:      page > 1,
		HasNext:      page < totalPages,
		PrevPage:     page - 1,
		NextPage:     page + 1,
	}

	if err := h.templates.ExecuteTemplate(w, "results.html", data); err != nil {
		log.Printf("[server] render results: %v", err)
	}
}

func (h *handlers) handleBrowse(w http.ResponseWriter, r *http.Request) {
	domains, err := h.idx.ListDomains()
	if err != nil {
		log.Printf("[server] list domains: %v", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}

	data := struct {
		Domains []index.DomainSummary
	}{Domains: domains}

	if err := h.templates.ExecuteTemplate(w, "browse.html", data); err != nil {
		log.Printf("[server] render browse: %v", err)
	}
}

func (h *handlers) handleBrowseDomain(w http.ResponseWriter, r *http.Request) {
	domain := strings.TrimPrefix(r.URL.Path, "/browse/")
	if domain == "" {
		http.Redirect(w, r, "/browse", http.StatusFound)
		return
	}

	pages, err := h.idx.ListPagesByDomain(domain)
	if err != nil {
		log.Printf("[server] list pages for %s: %v", domain, err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}

	if len(pages) == 0 {
		http.NotFound(w, r)
		return
	}

	data := struct {
		Domain string
		Pages  []index.PageSummary
	}{Domain: domain, Pages: pages}

	if err := h.templates.ExecuteTemplate(w, "domain.html", data); err != nil {
		log.Printf("[server] render domain: %v", err)
	}
}

// --- JSON API handlers ---

func (h *handlers) handleAPISearch(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing q parameter"})
		return
	}

	page := parseIntParam(r, "page", 1)

	results, total, err := h.idx.Search(query, page, defaultPageSize)
	if err != nil {
		log.Printf("[server] api search error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "search failed"})
		return
	}

	indexedPages, indexedDomains, _ := h.idx.Stats()

	resp := struct {
		Query   string               `json:"query"`
		Results []index.SearchResult `json:"results"`
		Pagination struct {
			Page     int `json:"page"`
			PageSize int `json:"page_size"`
			Total    int `json:"total"`
		} `json:"pagination"`
		IndexStatus struct {
			IndexedPages   int `json:"indexed_pages"`
			IndexedDomains int `json:"indexed_domains"`
		} `json:"index_status"`
	}{}
	resp.Query = query
	resp.Results = results
	if resp.Results == nil {
		resp.Results = []index.SearchResult{}
	}
	resp.Pagination.Page = page
	resp.Pagination.PageSize = defaultPageSize
	resp.Pagination.Total = total
	resp.IndexStatus.IndexedPages = indexedPages
	resp.IndexStatus.IndexedDomains = indexedDomains

	writeJSON(w, http.StatusOK, resp)
}

func (h *handlers) handleAPIBrowse(w http.ResponseWriter, r *http.Request) {
	domains, err := h.idx.ListDomains()
	if err != nil {
		log.Printf("[server] api browse error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to list domains"})
		return
	}
	if domains == nil {
		domains = []index.DomainSummary{}
	}
	writeJSON(w, http.StatusOK, domains)
}

func (h *handlers) handleAPIBrowseDomain(w http.ResponseWriter, r *http.Request) {
	domain := strings.TrimPrefix(r.URL.Path, "/api/browse/")
	if domain == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing domain"})
		return
	}

	pages, err := h.idx.ListPagesByDomain(domain)
	if err != nil {
		log.Printf("[server] api browse domain error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to list pages"})
		return
	}
	if pages == nil {
		pages = []index.PageSummary{}
	}
	writeJSON(w, http.StatusOK, struct {
		Domain string             `json:"domain"`
		Pages  []index.PageSummary `json:"pages"`
	}{Domain: domain, Pages: pages})
}

func (h *handlers) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

// --- helpers ---

// resultView wraps SearchResult for template rendering with unescaped snippet HTML.
type resultView struct {
	URL     string
	Title   string
	Snippet template.HTML
	Rank    float64
}

func toResultViews(results []index.SearchResult) []resultView {
	views := make([]resultView, len(results))
	for i, r := range results {
		views[i] = resultView{
			URL:     r.URL,
			Title:   r.Title,
			Snippet: template.HTML(r.Snippet),
			Rank:    r.Rank,
		}
	}
	return views
}

func parseIntParam(r *http.Request, name string, fallback int) int {
	s := r.URL.Query().Get(name)
	if s == "" {
		return fallback
	}
	v, err := strconv.Atoi(s)
	if err != nil || v < 1 {
		return fallback
	}
	return v
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
