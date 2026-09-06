package fmsteer

import (
	"encoding/base64"
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

func TestEndpointAuthPrefersAgentToken(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(AgentTokenEnv, "agent-tok")
	if err := WriteCreds("http://localhost:4000", "user-jwt", "local"); err != nil {
		t.Fatal(err)
	}
	base, token := endpointAuth("http://example.com")
	if base != "http://example.com" {
		t.Fatalf("base %q", base)
	}
	if token != "agent-tok" {
		t.Fatalf("expected agent token, got %q", token)
	}
}

func TestEndpointAuthDefaultsInstance(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(AgentTokenEnv, "agent-tok")
	base, _ := endpointAuth("")
	if base != "http://localhost:4000" {
		t.Fatalf("base %q", base)
	}
}

func TestMustCredsDefaultsInstance(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := WriteCreds("", "user-jwt", "local"); err != nil {
		t.Fatal(err)
	}
	c := MustCreds("")
	if c.Instance != "http://localhost:4000" {
		t.Fatalf("instance %q", c.Instance)
	}
}

func TestRollsPostSendsPayload(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(AgentTokenEnv, "agent-tok")
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/rolls" {
			t.Errorf("path %s", r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "r1"})
	}))
	defer srv.Close()
	rollsPost([]string{
		"--cluster", "c1", "--namespace", "ns", "--status", "success",
		"--image-tag", "sha-abc", "--pr-url", "https://github.com/o/r/pull/1",
		"--rebuilt", "web, worker", "--instance", srv.URL,
	})
	for k, want := range map[string]string{
		"cluster": "c1", "namespace": "ns", "status": "success", "image_tag": "sha-abc",
		"pr_url": "https://github.com/o/r/pull/1",
	} {
		if got[k] != want {
			t.Fatalf("%s = %v, want %s", k, got[k], want)
		}
	}
	rebuilt, _ := got["rebuilt"].([]any)
	if len(rebuilt) != 2 || rebuilt[0] != "web" || rebuilt[1] != "worker" {
		t.Fatalf("rebuilt = %v", got["rebuilt"])
	}
	if _, ok := got["issue_url"]; ok {
		t.Fatalf("empty issue_url should be omitted, got %v", got["issue_url"])
	}
}

func TestDiagramsPostSendsBase64(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(AgentTokenEnv, "agent-tok")
	html := "<html><body>hi</body></html>"
	htmlPath := filepath.Join(dir, "d.html")
	if err := os.WriteFile(htmlPath, []byte(html), 0o600); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/diagrams" {
			t.Errorf("path %s", r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "d1"})
	}))
	defer srv.Close()
	diagramsPost([]string{"--title", "T", "--html-file", htmlPath, "--instance", srv.URL})
	if got["title"] != "T" {
		t.Fatalf("title = %v", got["title"])
	}
	raw, err := base64.StdEncoding.DecodeString(got["html_base64"].(string))
	if err != nil || string(raw) != html {
		t.Fatalf("html round trip failed: %v %q", err, raw)
	}
}

func TestNoMistakesPostSendsPayload(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(AgentTokenEnv, "agent-tok")
	var gotPath string
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&got)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "n1"})
	}))
	defer srv.Close()
	noMistakesPost([]string{"--run-id", "run-1", "--branch", "fm/x", "--step", "review", "--instance", srv.URL})
	if gotPath != "/api/no-mistakes" {
		t.Fatalf("path %q", gotPath)
	}
	if got["run_id"] != "run-1" || got["branch"] != "fm/x" || got["step"] != "review" {
		t.Fatalf("payload = %v", got)
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

func TestDefaultInstanceIsLocalhost(t *testing.T) {
	if DefaultInstance != "http://localhost:4000" {
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
