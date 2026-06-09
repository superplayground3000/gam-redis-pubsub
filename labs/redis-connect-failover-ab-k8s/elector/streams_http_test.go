package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestDeleteTreats404AsSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()
	if err := newStreamsClient(srv.URL).delete(context.Background(), "x"); err != nil {
		t.Fatalf("DELETE 404 should be success, got %v", err)
	}
}

func TestPostNon2xxIsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	if err := newStreamsClient(srv.URL).post(context.Background(), "x", "in: {}"); err == nil {
		t.Fatal("POST 500 should return an error")
	}
}

func TestPostSendsYAMLContentType(t *testing.T) {
	got := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- r.Header.Get("Content-Type")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	if err := newStreamsClient(srv.URL).post(context.Background(), "x", "in: {}"); err != nil {
		t.Fatalf("POST 200 should succeed, got %v", err)
	}
	if ct := <-got; ct != "application/x-yaml" {
		t.Fatalf("Content-Type = %q, want application/x-yaml", ct)
	}
}

func TestRetryStopsOnContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already canceled
	calls := 0
	err := retry(ctx, 5, 10*time.Millisecond, func() error {
		calls++
		return http.ErrServerClosed // always fail
	})
	if err == nil {
		t.Fatal("retry with canceled ctx should return an error")
	}
	if calls != 1 {
		t.Fatalf("retry should stop after first failure on canceled ctx, calls=%d", calls)
	}
}
