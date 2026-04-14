package server

import (
	"context"
	"crypto/tls"
	"embed"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"time"

	"github.com/agent-testnet/testnet-search/index"
)

//go:embed templates/*.html
var templateFS embed.FS

// Server is the HTTPS search server.
type Server struct {
	httpServer *http.Server
}

// New creates a Server that serves search results from the given index.
// tlsCert is the node TLS certificate from the testnet CA.
func New(idx *index.Index, tlsCert tls.Certificate, listenAddr string) (*Server, error) {
	tmpl, err := template.ParseFS(templateFS, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("parse templates: %w", err)
	}

	h := &handlers{
		idx:       idx,
		templates: tmpl,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", h.handleHome)
	mux.HandleFunc("/search", h.handleSearch)
	mux.HandleFunc("/browse", h.handleBrowse)
	mux.HandleFunc("/browse/", h.handleBrowseDomain)
	mux.HandleFunc("/api/search", h.handleAPISearch)
	mux.HandleFunc("/api/browse", h.handleAPIBrowse)
	mux.HandleFunc("/api/browse/", h.handleAPIBrowseDomain)
	mux.HandleFunc("/health", h.handleHealth)

	srv := &http.Server{
		Addr:    listenAddr,
		Handler: mux,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{tlsCert},
		},
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	return &Server{httpServer: srv}, nil
}

// Start begins serving HTTPS. It blocks until the server is shut down.
func (s *Server) Start() error {
	log.Printf("[server] listening on %s", s.httpServer.Addr)
	err := s.httpServer.ListenAndServeTLS("", "")
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}

// Shutdown gracefully stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	return s.httpServer.Shutdown(ctx)
}
