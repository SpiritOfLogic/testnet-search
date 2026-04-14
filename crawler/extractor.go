package crawler

import (
	"bytes"
	"io"
	"net/url"
	"strings"

	readability "github.com/go-shiori/go-readability"
	"golang.org/x/net/html"
)

// ExtractResult holds the text content extracted from an HTML page.
type ExtractResult struct {
	Title       string
	Description string
	Content     string
}

// ExtractReadableText parses HTML and extracts the main readable text using
// go-readability. Falls back to raw tag stripping if readability fails.
func ExtractReadableText(body []byte, pageURL string) ExtractResult {
	u, _ := url.Parse(pageURL)

	article, err := readability.FromReader(bytes.NewReader(body), u)
	if err == nil && strings.TrimSpace(article.TextContent) != "" {
		return ExtractResult{
			Title:       article.Title,
			Description: article.Excerpt,
			Content:     article.TextContent,
		}
	}

	// Fallback: strip tags and extract title/meta manually.
	title, desc := extractMeta(body)
	text := stripTags(body)
	return ExtractResult{
		Title:       title,
		Description: desc,
		Content:     text,
	}
}

// ExtractLinks parses HTML and returns all absolute URLs found in <a href> tags.
// Links are resolved against baseURL and normalized.
func ExtractLinks(body []byte, baseURL *url.URL) []string {
	tokenizer := html.NewTokenizer(bytes.NewReader(body))
	seen := make(map[string]struct{})
	var links []string

	for {
		tt := tokenizer.Next()
		if tt == html.ErrorToken {
			break
		}
		if tt != html.StartTagToken && tt != html.SelfClosingTagToken {
			continue
		}
		t := tokenizer.Token()
		if t.Data != "a" {
			continue
		}
		for _, attr := range t.Attr {
			if attr.Key != "href" {
				continue
			}
			resolved := resolveURL(attr.Val, baseURL)
			if resolved == "" {
				continue
			}
			normalized := normalizeURL(resolved)
			if normalized == "" {
				continue
			}
			if _, ok := seen[normalized]; ok {
				continue
			}
			seen[normalized] = struct{}{}
			links = append(links, normalized)
		}
	}
	return links
}

// NormalizeURL canonicalizes a URL for deduplication: lowercase host,
// strip fragment, strip trailing slash.
func NormalizeURL(rawURL string) string {
	return normalizeURL(rawURL)
}

func normalizeURL(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return ""
	}
	u.Host = strings.ToLower(u.Host)
	u.Fragment = ""
	u.RawFragment = ""
	p := u.Path
	if len(p) > 1 {
		p = strings.TrimRight(p, "/")
	}
	u.Path = p
	return u.String()
}

func resolveURL(href string, base *url.URL) string {
	href = strings.TrimSpace(href)
	if href == "" || strings.HasPrefix(href, "javascript:") || strings.HasPrefix(href, "mailto:") {
		return ""
	}
	ref, err := url.Parse(href)
	if err != nil {
		return ""
	}
	return base.ResolveReference(ref).String()
}

// extractMeta pulls <title> and <meta name="description"> from raw HTML.
func extractMeta(body []byte) (title, description string) {
	tokenizer := html.NewTokenizer(bytes.NewReader(body))
	inTitle := false

	for {
		tt := tokenizer.Next()
		if tt == html.ErrorToken {
			break
		}

		switch tt {
		case html.StartTagToken:
			t := tokenizer.Token()
			if t.Data == "title" {
				inTitle = true
			}
			if t.Data == "meta" {
				var name, content string
				for _, a := range t.Attr {
					switch strings.ToLower(a.Key) {
					case "name":
						name = strings.ToLower(a.Val)
					case "content":
						content = a.Val
					}
				}
				if name == "description" {
					description = content
				}
			}
		case html.TextToken:
			if inTitle {
				title = strings.TrimSpace(tokenizer.Token().Data)
			}
		case html.EndTagToken:
			if tokenizer.Token().Data == "title" {
				inTitle = false
			}
		}
	}
	return
}

// stripTags removes all HTML tags and returns the concatenated text content.
func stripTags(body []byte) string {
	tokenizer := html.NewTokenizer(bytes.NewReader(body))
	var b strings.Builder

	for {
		tt := tokenizer.Next()
		if tt == html.ErrorToken {
			if tokenizer.Err() == io.EOF {
				break
			}
			break
		}
		if tt == html.TextToken {
			text := strings.TrimSpace(tokenizer.Token().Data)
			if text != "" {
				if b.Len() > 0 {
					b.WriteByte(' ')
				}
				b.WriteString(text)
			}
		}
	}
	return b.String()
}
