package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCredentialsMode0600(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := writeCreds("http://localhost:4000", "tok", "local"); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(credsPath())
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o", st.Mode().Perm())
	}
}

func TestDeviceLoginStoresToken(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	var polls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/cli/auth/device":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"device_code":               "dev",
				"user_code":                 "ABCD-EFGH",
				"verification_uri":          "http://example/login/device",
				"verification_uri_complete": "http://example/login/device?user_code=ABCD-EFGH",
				"expires_in":                60,
				"interval":                  1,
			})
		case "/api/cli/auth/token":
			polls++
			if polls < 2 {
				w.WriteHeader(400)
				_ = json.NewEncoder(w).Encode(map[string]string{"error": "authorization_pending"})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"access_token": "jwt", "tenant": "local"})
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	os.Args = []string{"fm-steer", "auth", "login", "--instance", srv.URL}
	// Call the login helper directly with a short path:
	authLogin([]string{"--instance", srv.URL})
	c, err := readCreds()
	if err != nil {
		t.Fatal(err)
	}
	if c.Token != "jwt" {
		t.Fatalf("token %q", c.Token)
	}
	if _, err := os.ReadFile(filepath.Join(dir, "fm-steer", "credentials.json")); err != nil {
		t.Fatal(err)
	}
}

func TestInboxPutGoesToHTTP(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	var gotTask string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/cli/inbox/put" {
			t.Errorf("path %s", r.URL.Path)
		}
		if r.Header.Get("authorization") != "Bearer jwt" {
			t.Errorf("auth %s", r.Header.Get("authorization"))
		}
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotTask = body["task"]
		_ = json.NewEncoder(w).Encode(map[string]any{"seq": 1, "task": body["task"]})
	}))
	defer srv.Close()
	if err := writeCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	inboxPut([]string{"--task", "fm-port", "--body", "hello", "--instance", srv.URL})
	if gotTask != "fm-port" {
		t.Fatalf("task %q", gotTask)
	}
}

func TestRoutePostsDescriptionToPortal(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	var gotDesc string
	var gotIntel bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/route" {
			t.Errorf("path %s", r.URL.Path)
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotDesc, _ = body["description"].(string)
		gotIntel, _ = body["intel"].(bool)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"tenant": "local", "harness": "codex", "model": "harness-default",
			"model_source": "harness_default", "effort": "medium",
			"reasons":       []string{"kind=code matches codex lane"},
			"intel_sources": []string{"fleet_matrix", "fleet_evals"},
		})
	}))
	defer srv.Close()
	if err := writeCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	routeRun([]string{"--instance", srv.URL, "--intel", "fix the portal test"})
	if gotDesc != "fix the portal test" {
		t.Fatalf("description %q", gotDesc)
	}
	if !gotIntel {
		t.Fatal("intel flag was not forwarded")
	}
}

func TestUsageListsAccountsFromPortal(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_ = json.NewEncoder(w).Encode(map[string]any{
			"tenant": "local",
			"data": []map[string]any{
				{"provider": "openrouter", "label": "captain", "allowance": 100.0,
					"used": 25.0, "remaining": 75.0, "status": "ok"},
			},
		})
	}))
	defer srv.Close()
	if err := writeCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	usageRun([]string{"--instance", srv.URL})
	if gotPath != "/api/usage" {
		t.Fatalf("path %s", gotPath)
	}
}

func TestUsageSyncPostsToPortal(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_ = json.NewEncoder(w).Encode(map[string]any{"tenant": "local", "data": []any{}})
	}))
	defer srv.Close()
	if err := writeCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	usageRun([]string{"--instance", srv.URL, "--sync"})
	if gotPath != "/api/usage/sync" {
		t.Fatalf("path %s", gotPath)
	}
}

func TestGetJSONFailsOnUnauthorized(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
	}))
	defer srv.Close()
	var out map[string]any
	err := getJSON(srv.URL+"/api/usage", "stale", &out)
	if err == nil {
		t.Fatal("HTTP 401 was reported as success")
	}
	if !strings.Contains(err.Error(), "unauthorized") {
		t.Fatalf("error %v drops the portal message", err)
	}
}

func TestPostJSONFailsOnNotFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "not_found"})
	}))
	defer srv.Close()
	var out map[string]any
	err := postJSON(srv.URL+"/api/cli/inbox/ack", "jwt", map[string]string{"ack": "999"}, &out)
	if err == nil {
		t.Fatal("HTTP 404 was reported as success")
	}
	if !strings.Contains(err.Error(), "not_found") {
		t.Fatalf("error %v drops the portal message", err)
	}
}

func TestPostJSONStatusAcceptsEmptyInbox(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	var out map[string]any
	status, err := postJSONStatus(srv.URL+"/api/cli/inbox/next", "jwt", map[string]string{}, &out)
	if err != nil {
		t.Fatalf("HTTP 204 must not be an error: %v", err)
	}
	if status != http.StatusNoContent {
		t.Fatalf("status %d", status)
	}
}
