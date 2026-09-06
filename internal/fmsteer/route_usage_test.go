package fmsteer

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

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
			"tenant": "local", "harness": "codex", "model": "gpt-6-astra",
			"model_display": "GPT-6-Astra", "model_source": "fleet_matrix", "effort": "medium",
			"reasons":       []string{"kind=code matches codex lane"},
			"intel_sources": []string{"fleet_matrix", "fleet_evals"},
		})
	}))
	defer srv.Close()
	if err := WriteCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	RouteRun([]string{"--instance", srv.URL, "--intel", "fix the portal test"})
	if gotDesc != "fix the portal test" {
		t.Fatalf("description %q", gotDesc)
	}
	if !gotIntel {
		t.Fatal("intel flag was not forwarded")
	}
}

func TestRouteFlagsWorkInEitherPosition(t *testing.T) {
	for _, tc := range []struct {
		name string
		args func(url string) []string
	}{
		{"flags first", func(u string) []string {
			return []string{"--instance", u, "--intel", "--json", "fix the failing test"}
		}},
		{"flags after the task", func(u string) []string {
			return []string{"--instance", u, "fix the failing test", "--intel", "--json"}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("XDG_CONFIG_HOME", dir)
			var gotDesc string
			var gotIntel bool
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				_ = json.NewDecoder(r.Body).Decode(&body)
				gotDesc, _ = body["description"].(string)
				gotIntel, _ = body["intel"].(bool)
				_ = json.NewEncoder(w).Encode(map[string]any{
					"harness": "codex", "model": "gpt-6-astra", "effort": "medium",
				})
			}))
			defer srv.Close()
			if err := WriteCreds(srv.URL, "jwt", "local"); err != nil {
				t.Fatal(err)
			}

			out := captureStdout(t, func() { RouteRun(tc.args(srv.URL)) })

			if gotDesc != "fix the failing test" {
				t.Errorf("task text was corrupted by a flag: %q", gotDesc)
			}
			if !gotIntel {
				t.Error("--intel was not honored")
			}
			var decoded map[string]any
			if err := json.Unmarshal([]byte(out), &decoded); err != nil {
				t.Fatalf("--json was not honored, got %q", out)
			}
			if decoded["harness"] != "codex" {
				t.Errorf("harness %v", decoded["harness"])
			}
		})
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
				{"provider": "anthropic", "label": "captain", "allowance": 100.0,
					"used": 25.0, "remaining": 75.0, "status": "ok"},
			},
		})
	}))
	defer srv.Close()
	if err := WriteCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	UsageRun([]string{"--instance", srv.URL})
	if gotPath != "/api/usage" {
		t.Fatalf("path %s", gotPath)
	}
}

func TestUsageJSONPassesLedgerThrough(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"tenant": "local",
			"data": []map[string]any{
				{"id": "acct-1", "provider": "anthropic", "label": "captain",
					"allowance": 100.0, "used": 25.0, "remaining": 75.0, "status": "ok",
					"pct_used": 0.25, "spend_priority": 10},
			},
		})
	}))
	defer srv.Close()
	if err := WriteCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}

	out := captureStdout(t, func() { UsageRun([]string{"--instance", srv.URL, "--json"}) })

	var got struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("--json did not emit JSON: %v (%s)", err, out)
	}
	if len(got.Data) != 1 {
		t.Fatalf("data %v", got.Data)
	}
	for _, key := range []string{"id", "spend_priority", "pct_used"} {
		if _, ok := got.Data[0][key]; !ok {
			t.Errorf("--json dropped %q from the portal ledger", key)
		}
	}
}

func TestGetJSONFailsOnUnauthorized(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
	}))
	defer srv.Close()
	var out map[string]any
	err := GetJSON(srv.URL+"/api/usage", "stale", &out)
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
	err := PostJSON(srv.URL+"/api/cli/inbox/ack", "jwt", map[string]string{"ack": "999"}, &out)
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
	status, err := PostJSONStatus(srv.URL+"/api/cli/inbox/next", "jwt", map[string]string{}, &out)
	if err != nil {
		t.Fatalf("HTTP 204 must not be an error: %v", err)
	}
	if status != http.StatusNoContent {
		t.Fatalf("status %d", status)
	}
}

func TestGetJSONFailsOnNonJSONSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "text/html")
		_, _ = w.Write([]byte("<html><body>sign in</body></html>"))
	}))
	defer srv.Close()
	var out struct {
		Data []map[string]any `json:"data"`
	}
	err := GetJSON(srv.URL+"/api/usage", "jwt", &out)
	if err == nil {
		t.Fatal("HTTP 200 with an HTML body was reported as success")
	}
}

// captureStdout runs fn with os.Stdout redirected and returns what it wrote.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	orig := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = orig }()
	fn()
	_ = w.Close()
	raw, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
