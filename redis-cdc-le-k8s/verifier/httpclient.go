package main

import (
	"net/http"
	"time"
)

// httpClient is shared by ScrapeJSZ (nats.go). The parent declared it in
// scrapers.go, which this lab deletes (no per-pod scraping), so it lives here.
var httpClient = &http.Client{Timeout: 5 * time.Second}
