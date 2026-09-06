package fmsteer

import (
	"encoding/base64"
	"encoding/json"
	"errors"
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

func TestProgressPostSendsEvents(t *testing.T) {
	t.Setenv(AgentTokenEnv, "progress-agent")
	var payloads []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/progress/events" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer progress-agent" {
			t.Error("missing agent credential")
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		payloads = append(payloads, payload)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "event-1"})
	}))
	defer srv.Close()
	if Run([]string{"progress", "post", "--instance", srv.URL,
		"--item-id", "work-1", "--type", "contribution", "--worker", "crew-a",
		"--role", "review", "--runtime", "codex", "--model", "test-model", "--effort", "high",
		"--tokens", "0", "--duration-ms", "0", "--interrupted=false"}) != 0 {
		t.Fatal("command failed")
	}
	Run([]string{"progress", "post", "--instance", srv.URL,
		"--url", "https://github.com/example/repo/pull/1", "--type", "status",
		"--status", "merged", "--occurred-at", "2026-09-01T12:00:00Z"})
	if len(payloads) != 2 {
		t.Fatalf("got %d requests", len(payloads))
	}
	first := payloads[0]
	for key, expected := range map[string]any{"item_id": "work-1", "type": "contribution",
		"worker": "crew-a", "role": "review", "runtime": "codex", "model": "test-model",
		"effort": "high", "tokens": float64(0), "duration_ms": float64(0), "interrupted": false} {
		if first[key] != expected {
			t.Errorf("%s = %v; want %v", key, first[key], expected)
		}
	}
	second := payloads[1]
	if second["status"] != "merged" || second["occurred_at"] != "2026-09-01T12:00:00Z" {
		t.Fatalf("unexpected status event: %v", second)
	}
	for _, key := range []string{"tokens", "duration_ms", "interrupted"} {
		if _, ok := second[key]; ok {
			t.Errorf("omitted telemetry %s was sent", key)
		}
	}
}

func TestRequestsCarryTheUserAgent(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("user-agent")
		_ = json.NewEncoder(w).Encode(map[string]any{"seq": 1})
	}))
	defer srv.Close()
	if err := WriteCreds(srv.URL, "jwt", "local"); err != nil {
		t.Fatal(err)
	}
	InboxPut([]string{"--body", "hello", "--instance", srv.URL})
	if got != UserAgent {
		t.Fatalf("user-agent %q, want %q", got, UserAgent)
	}
}

func TestRevokedTokenSaysToSignInAgain(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
	}))
	defer srv.Close()

	if _, err := PostJSONStatus(srv.URL, "revoked-jwt", map[string]string{}, nil); !errors.Is(err, ErrSignedOut) {
		t.Fatalf("post error %v, want ErrSignedOut", err)
	}
	if err := GetJSON(srv.URL, "revoked-jwt", nil); !errors.Is(err, ErrSignedOut) {
		t.Fatalf("get error %v, want ErrSignedOut", err)
	}
	// The device-code poll is unauthenticated by design and must keep working.
	if _, err := PostJSONStatus(srv.URL, "", map[string]string{}, nil); err != nil {
		t.Fatalf("unauthenticated poll errored: %v", err)
func TestQueuePostSendsSparsePayload(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(AgentTokenEnv, "agent-tok")
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != QueuePath {
			t.Errorf("path %s", r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		_ = json.NewEncoder(w).Encode(map[string]any{"task": "t1"})
	}))
	defer srv.Close()
	queuePost([]string{
		"--task", "t1", "--worker", "crew-4", "--agent-id", "agent-7b1",
		"--status", "working", "--model", "claude-opus-5", "--effort", "high",
		"--tokens-in", "9000", "--tokens-out", "0", "--instance", srv.URL,
	})
	for k, want := range map[string]string{
		"task": "t1", "worker": "crew-4", "agent_id": "agent-7b1",
		"status": "working", "model": "claude-opus-5", "effort": "high",
	} {
		if got[k] != want {
			t.Fatalf("%s = %v, want %s", k, got[k], want)
		}
	}
	if got["tokens_in"] != float64(9000) {
		t.Fatalf("tokens_in = %v", got["tokens_in"])
	}
	// Zero is a real report; only an omitted counter is left out.
	if got["tokens_out"] != float64(0) {
		t.Fatalf("tokens_out = %v", got["tokens_out"])
	}
	for _, k := range []string{"summary", "started_at", "stopped_at"} {
		if _, ok := got[k]; ok {
			t.Fatalf("%s should be omitted, got %v", k, got[k])
		}
	}
}

func TestQueueListReadsTheLookIn(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(AgentTokenEnv, "agent-tok")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != QueuePath {
			t.Errorf("%s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("authorization"); got != "Bearer agent-tok" {
			t.Errorf("authorization %q", got)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"task": "t1"}}})
	}))
	defer srv.Close()
	queueList([]string{"--instance", srv.URL})
}

func TestQueuePostOmitsCountersNeverGiven(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv(AgentTokenEnv, "agent-tok")
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		_ = json.NewEncoder(w).Encode(map[string]any{"task": "t1"})
	}))
	defer srv.Close()
	queuePost([]string{"--task", "t1", "--instance", srv.URL})
	if got["task"] != "t1" {
		t.Fatalf("task = %v", got["task"])
	}
	// A sparse report must stay sparse: the portal merges, it does not replace.
	for _, k := range []string{"tokens_in", "tokens_out", "worker", "status", "model", "effort"} {
		if _, ok := got[k]; ok {
			t.Fatalf("%s should be omitted, got %v", k, got[k])
		}
	}
}

// queue list must never mistake a refused read for an empty look-in. The
// portal's shared GetJSON turns a non-2xx into an error, whether or not the
// body is JSON, so the CLI reports the refusal instead of printing nothing.
func TestQueueListRefusalIsAnErrorNotAnEmptyLookIn(t *testing.T) {
	for _, body := range []string{"<html>Bad Gateway</html>", ""} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(body))
		}))
		var out map[string]any
		err := GetJSON(srv.URL+QueuePath, "", &out)
		srv.Close()
		if err == nil {
			t.Fatalf("a 502 with body %q was accepted as a look-in", body)
		}
	}
}
