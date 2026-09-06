package fmsteer

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestCredentialsMode0600(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := WriteCreds("http://localhost:4000", "tok", "local"); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(CredsPath())
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
	// Call the login helper directly with a short path:
	AuthLogin([]string{"--instance", srv.URL})
	c, err := ReadCreds()
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
	if err := WriteCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	InboxPut([]string{"--task", "fm-port", "--body", "hello", "--instance", srv.URL})
	if gotTask != "fm-port" {
		t.Fatalf("task %q", gotTask)
	}
}

func TestInboxPutDefaultsTaskToFirstmate(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	var gotTask string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotTask = body["task"]
		_ = json.NewEncoder(w).Encode(map[string]any{"seq": 1, "task": body["task"]})
	}))
	defer srv.Close()
	if err := WriteCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	InboxPut([]string{"--body", "hello from second mate", "--instance", srv.URL})
	if gotTask != DefaultTask {
		t.Fatalf("task %q, want %q", gotTask, DefaultTask)
	}
}

func TestDefaultInstanceIsLivePortal(t *testing.T) {
	if DefaultInstance != "https://firstmate.carverauto.dev" {
		t.Fatalf("default %q", DefaultInstance)
	}
	t.Setenv("FIRSTMATE_INSTANCE", "http://localhost:4000")
	if got := Env("FIRSTMATE_INSTANCE", DefaultInstance); got != "http://localhost:4000" {
		t.Fatalf("override %q", got)
	}
}

func TestRunRejectsUnknownSubcommand(t *testing.T) {
	if got := Run([]string{"bogus"}); got != 2 {
		t.Fatalf("exit %d", got)
	}
	if got := Run(nil); got != 2 {
		t.Fatalf("exit %d", got)
	}
	if got := Run([]string{"auth", "bogus"}); got != 2 {
		t.Fatalf("exit %d", got)
	}
	if got := Run([]string{"inbox", "bogus"}); got != 2 {
		t.Fatalf("exit %d", got)
	}
}
