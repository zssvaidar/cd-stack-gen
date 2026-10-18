package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestHealth(t *testing.T) {
	var ready atomic.Bool
	mux := newMux(&ready)

	cases := []struct {
		path  string
		ready bool
		want  int
	}{
		{"/", true, http.StatusOK},
		{"/health", false, http.StatusOK},
		{"/health/ready", false, http.StatusServiceUnavailable},
		{"/health/ready", true, http.StatusOK},
		{"/metrics", true, http.StatusOK},
		{"/missing", true, http.StatusNotFound},
	}
	for _, c := range cases {
		ready.Store(c.ready)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, c.path, nil))
		if rec.Code != c.want {
			t.Errorf("GET %s (ready=%v) = %d, want %d", c.path, c.ready, rec.Code, c.want)
		}
	}
}
