#!/usr/bin/env bash
# Builds "Shelfie", a tiny Go reading-list service. feature/paginate-books is a small,
# cohesive change (cursor pagination on one endpoint) that should NOT be split.
set -euo pipefail

git init -q -b main
git config user.name "Fixture Bot"
git config user.email fixture@example.com

commit() {
  export GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1"
  git add -A
  git commit -q -m "$2"
}

mkdir -p internal/books cmd/shelfie

cat > go.mod <<'EOF'
module example.com/shelfie

go 1.22
EOF

cat > README.md <<'EOF'
# Shelfie

A tiny reading-list service.

    go run ./cmd/shelfie
    go test ./...

## API

- `GET /books` lists every book on the shelf.
- `POST /books` adds a book.
EOF

cat > internal/books/book.go <<'EOF'
package books

// Book is one entry on a reading list.
type Book struct {
	ID     int    `json:"id"`
	Title  string `json:"title"`
	Author string `json:"author"`
}
EOF

cat > internal/books/store.go <<'EOF'
package books

import "sync"

// Store is an in-memory, ID-ordered book store.
type Store struct {
	mu    sync.RWMutex
	books []Book
	next  int
}

func NewStore() *Store { return &Store{next: 1} }

// Add appends a book and assigns it the next ID.
func (s *Store) Add(title, author string) Book {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := Book{ID: s.next, Title: title, Author: author}
	s.next++
	s.books = append(s.books, b)
	return b
}

// All returns every book in ID order.
func (s *Store) All() []Book {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Book, len(s.books))
	copy(out, s.books)
	return out
}
EOF

cat > internal/books/handler.go <<'EOF'
package books

import (
	"encoding/json"
	"net/http"
)

// Handler serves the /books endpoints.
type Handler struct{ Store *Store }

func (h Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, h.Store.All())
	case http.MethodPost:
		var in struct{ Title, Author string }
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Title == "" {
			http.Error(w, "title is required", http.StatusBadRequest)
			return
		}
		writeJSON(w, http.StatusCreated, h.Store.Add(in.Title, in.Author))
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
EOF

cat > internal/books/handler_test.go <<'EOF'
package books

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPostThenList(t *testing.T) {
	h := Handler{Store: NewStore()}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/books", strings.NewReader(`{"Title":"Dune","Author":"Herbert"}`)))
	if rec.Code != http.StatusCreated {
		t.Fatalf("post: got %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/books", nil))
	if !strings.Contains(rec.Body.String(), "Dune") {
		t.Fatalf("list: missing book: %s", rec.Body.String())
	}
}
EOF

cat > cmd/shelfie/main.go <<'EOF'
package main

import (
	"log"
	"net/http"

	"example.com/shelfie/internal/books"
)

func main() {
	http.Handle("/books", books.Handler{Store: books.NewStore()})
	log.Fatal(http.ListenAndServe(":8080", nil))
}
EOF
commit "2026-03-02T10:00:00Z" "Initial reading-list service"

git checkout -q -b feature/paginate-books

cat > internal/books/page.go <<'EOF'
package books

import (
	"errors"
	"strconv"
)

// DefaultLimit and MaxLimit bound how many books one page returns.
const (
	DefaultLimit = 20
	MaxLimit     = 100
)

// Page is one slice of the shelf plus the cursor for the next slice.
type Page struct {
	Books      []Book `json:"books"`
	NextCursor string `json:"next_cursor,omitempty"`
}

var errBadLimit = errors.New("limit must be between 1 and 100")

// parseLimit reads the ?limit= query value, applying the default and bounds.
func parseLimit(raw string) (int, error) {
	if raw == "" {
		return DefaultLimit, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > MaxLimit {
		return 0, errBadLimit
	}
	return n, nil
}
EOF

cat > internal/books/store.go <<'EOF'
package books

import "sync"

// Store is an in-memory, ID-ordered book store.
type Store struct {
	mu    sync.RWMutex
	books []Book
	next  int
}

func NewStore() *Store { return &Store{next: 1} }

// Add appends a book and assigns it the next ID.
func (s *Store) Add(title, author string) Book {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := Book{ID: s.next, Title: title, Author: author}
	s.next++
	s.books = append(s.books, b)
	return b
}

// All returns every book in ID order.
func (s *Store) All() []Book {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Book, len(s.books))
	copy(out, s.books)
	return out
}

// After returns up to limit books whose ID is greater than afterID, and whether more remain.
func (s *Store) After(afterID, limit int) ([]Book, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []Book
	for _, b := range s.books {
		if b.ID <= afterID {
			continue
		}
		if len(out) == limit {
			return out, true
		}
		out = append(out, b)
	}
	return out, false
}
EOF
commit "2026-03-03T09:00:00Z" "Add Store.After and page types"

cat > internal/books/handler.go <<'EOF'
package books

import (
	"encoding/json"
	"net/http"
	"strconv"
)

// Handler serves the /books endpoints.
type Handler struct{ Store *Store }

func (h Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		h.list(w, r)
	case http.MethodPost:
		var in struct{ Title, Author string }
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Title == "" {
			http.Error(w, "title is required", http.StatusBadRequest)
			return
		}
		writeJSON(w, http.StatusCreated, h.Store.Add(in.Title, in.Author))
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// list returns one page of books. ?cursor= is the last ID of the previous page.
func (h Handler) list(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, err := parseLimit(q.Get("limit"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	after := 0
	if c := q.Get("cursor"); c != "" {
		if after, err = strconv.Atoi(c); err != nil || after < 0 {
			http.Error(w, "invalid cursor", http.StatusBadRequest)
			return
		}
	}
	books, more := h.Store.After(after, limit)
	page := Page{Books: books}
	if more {
		page.NextCursor = strconv.Itoa(books[len(books)-1].ID)
	}
	writeJSON(w, http.StatusOK, page)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
EOF

cat > internal/books/handler_test.go <<'EOF'
package books

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPostThenList(t *testing.T) {
	h := Handler{Store: NewStore()}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/books", strings.NewReader(`{"Title":"Dune","Author":"Herbert"}`)))
	if rec.Code != http.StatusCreated {
		t.Fatalf("post: got %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/books", nil))
	if !strings.Contains(rec.Body.String(), "Dune") {
		t.Fatalf("list: missing book: %s", rec.Body.String())
	}
}

func TestListPaginates(t *testing.T) {
	s := NewStore()
	for i := 1; i <= 5; i++ {
		s.Add(fmt.Sprintf("Book %d", i), "Anon")
	}
	h := Handler{Store: s}

	get := func(url string) Page {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, url, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: got %d", url, rec.Code)
		}
		var p Page
		if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
			t.Fatal(err)
		}
		return p
	}

	p1 := get("/books?limit=2")
	if len(p1.Books) != 2 || p1.NextCursor != "2" {
		t.Fatalf("page 1: %+v", p1)
	}
	p3 := get("/books?limit=2&cursor=4")
	if len(p3.Books) != 1 || p3.NextCursor != "" {
		t.Fatalf("last page: %+v", p3)
	}
}

func TestListRejectsBadLimit(t *testing.T) {
	h := Handler{Store: NewStore()}
	for _, url := range []string{"/books?limit=0", "/books?limit=101", "/books?limit=x", "/books?cursor=-1"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, url, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", url, rec.Code)
		}
	}
}
EOF

cat > README.md <<'EOF'
# Shelfie

A tiny reading-list service.

    go run ./cmd/shelfie
    go test ./...

## API

- `GET /books?limit=20&cursor=<id>` lists books one page at a time. `limit` is 1–100
  (default 20). Pass the response's `next_cursor` as `cursor` to get the next page;
  it's absent on the last page.
- `POST /books` adds a book.
EOF
commit "2026-03-03T11:30:00Z" "Paginate GET /books with limit and cursor"

git checkout -q feature/paginate-books
