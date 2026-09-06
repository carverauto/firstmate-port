package fmsteer

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// buildServer captures the single ingest POST a build command makes.
func buildServer(t *testing.T, got *map[string]any, path *string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*path = r.URL.Path
		if err := json.NewDecoder(r.Body).Decode(got); err != nil {
			t.Errorf("decode body: %v", err)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "b1", "run_id": (*got)["run_id"]})
	}))
}

func TestBuildStartGeneratesRunID(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv(AgentTokenEnv, "agent-tok")
	var got map[string]any
	var path string
	srv := buildServer(t, &got, &path)
	defer srv.Close()

	buildStart([]string{
		"--kind", "docker", "--target", "firstmate-port",
		"--agent-id", "crew-7", "--model", "opus-5", "--effort", "high",
		"--instance", srv.URL,
	})

	if path != "/api/build-events" {
		t.Fatalf("path %q", path)
	}
	if got["status"] != "started" {
		t.Fatalf("status = %v, want started", got["status"])
	}
	runID, _ := got["run_id"].(string)
	if len(runID) < 8 {
		t.Fatalf("run_id = %q, want a generated id", runID)
	}
	for field, want := range map[string]string{
		"kind": "docker", "target": "firstmate-port",
		"agent_id": "crew-7", "model": "opus-5", "effort": "high",
	} {
		if got[field] != want {
			t.Fatalf("%s = %v, want %s", field, got[field], want)
		}
	}
	if _, err := time.Parse(time.RFC3339, got["started_at"].(string)); err != nil {
		t.Fatalf("started_at %v: %v", got["started_at"], err)
	}
	for _, omitted := range []string{"finished_at", "cluster", "namespace", "tokens", "pr_url"} {
		if _, ok := got[omitted]; ok {
			t.Fatalf("start should omit %s, got %v", omitted, got[omitted])
		}
	}
}

func TestBuildStartKeepsSuppliedRunIDAndTime(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv(AgentTokenEnv, "agent-tok")
	var got map[string]any
	var path string
	srv := buildServer(t, &got, &path)
	defer srv.Close()

	buildStart([]string{
		"--run-id", "run-abc", "--kind", "k8s",
		"--cluster", "farm01", "--namespace", "serviceradar",
		"--image", "ghcr.io/example/app", "--image-tag", "sha-deadbeef",
		"--started-at", "2026-09-06T01:02:03Z",
		"--instance", srv.URL,
	})

	if got["run_id"] != "run-abc" {
		t.Fatalf("run_id = %v", got["run_id"])
	}
	if got["started_at"] != "2026-09-06T01:02:03Z" {
		t.Fatalf("started_at = %v", got["started_at"])
	}
	for field, want := range map[string]string{
		"cluster": "farm01", "namespace": "serviceradar",
		"image": "ghcr.io/example/app", "image_tag": "sha-deadbeef",
	} {
		if got[field] != want {
			t.Fatalf("%s = %v, want %s", field, got[field], want)
		}
	}
}

func TestBuildFinishSendsOutcomeAndTokens(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv(AgentTokenEnv, "agent-tok")
	var got map[string]any
	var path string
	srv := buildServer(t, &got, &path)
	defer srv.Close()

	buildFinish([]string{
		"--run-id", "run-abc", "--status", "failure", "--tokens", "48210",
		"--outcome", "helm rollback", "--instance", srv.URL,
	})

	if got["status"] != "failure" {
		t.Fatalf("status = %v", got["status"])
	}
	if got["tokens"] != float64(48210) {
		t.Fatalf("tokens = %v", got["tokens"])
	}
	if got["outcome"] != "helm rollback" {
		t.Fatalf("outcome = %v", got["outcome"])
	}
	if _, err := time.Parse(time.RFC3339, got["finished_at"].(string)); err != nil {
		t.Fatalf("finished_at %v: %v", got["finished_at"], err)
	}
	// A finish inherits the run's context server-side, so it need not repeat it.
	if _, ok := got["kind"]; ok {
		t.Fatalf("finish should omit kind when not given, got %v", got["kind"])
	}
}

func TestBuildFlagsFallBackToEnv(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv(AgentTokenEnv, "agent-tok")
	t.Setenv(AgentIDEnv, "crew-env")
	t.Setenv(ModelEnv, "sonnet-5")
	t.Setenv(EffortEnv, "medium")
	var got map[string]any
	var path string
	srv := buildServer(t, &got, &path)
	defer srv.Close()

	buildStart([]string{"--kind", "bazel", "--instance", srv.URL})

	for field, want := range map[string]string{
		"agent_id": "crew-env", "model": "sonnet-5", "effort": "medium",
	} {
		if got[field] != want {
			t.Fatalf("%s = %v, want %s", field, got[field], want)
		}
	}
}

func TestBuildRejectsUnknownSubcommand(t *testing.T) {
	if code := Run([]string{"build", "bogus"}); code != 2 {
		t.Fatalf("exit %d", code)
	}
	if code := Run([]string{"build"}); code != 2 {
		t.Fatalf("exit %d", code)
	}
}

func TestRunIDIsUnique(t *testing.T) {
	seen := map[string]bool{}
	for range 100 {
		id := newRunID()
		if seen[id] {
			t.Fatalf("duplicate run id %q", id)
		}
		seen[id] = true
	}
}

func TestValidFinishStatus(t *testing.T) {
	for _, ok := range []string{"success", "failure", "cancelled"} {
		if !validFinishStatus(ok) {
			t.Fatalf("%q should be valid", ok)
		}
	}
	for _, bad := range []string{"", "started", "done", "SUCCESS"} {
		if validFinishStatus(bad) {
			t.Fatalf("%q should be invalid", bad)
		}
	}
}

func TestTimestampEchoesExplicitValue(t *testing.T) {
	if got := timestamp(" 2026-09-06T01:02:03Z "); got != "2026-09-06T01:02:03Z" {
		t.Fatalf("timestamp = %q", got)
	}
	if _, err := time.Parse(time.RFC3339, timestamp("")); err != nil {
		t.Fatalf("default timestamp: %v", err)
	}
}

func TestBuildAttributionDefaultsOnlyOnStart(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv(AgentTokenEnv, "agent-tok")
	t.Setenv(AgentIDEnv, "crew-env")
	t.Setenv(ModelEnv, "model-env")
	t.Setenv(EffortEnv, "effort-env")
	for _, tc := range []struct {
		name    string
		command []string
		want    map[string]string
	}{
		{"start defaults", []string{"start", "--kind", "docker"}, map[string]string{"agent_id": "crew-env", "model": "model-env", "effort": "effort-env"}},
		{"start overrides", []string{"start", "--kind", "docker", "--agent-id", "crew-flag", "--model", "model-flag", "--effort", "high"}, map[string]string{"agent_id": "crew-flag", "model": "model-flag", "effort": "high"}},
		{"finish omits defaults", []string{"finish", "--run-id", "run-abc"}, nil},
		{"finish explicit model", []string{"finish", "--run-id", "run-abc", "--model", "model-flag"}, map[string]string{"model": "model-flag"}},
		{"finish explicit attribution", []string{"finish", "--run-id", "run-abc", "--agent-id", "crew-flag", "--model", "model-flag", "--effort", "high"}, map[string]string{"agent_id": "crew-flag", "model": "model-flag", "effort": "high"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var got map[string]any
			var path string
			srv := buildServer(t, &got, &path)
			defer srv.Close()
			args := append([]string{"build"}, tc.command...)
			args = append(args, "--instance", srv.URL)
			if code := Run(args); code != 0 {
				t.Fatalf("exit %d", code)
			}
			for _, field := range []string{"agent_id", "model", "effort"} {
				value, present := got[field]
				want, expected := tc.want[field]
				if present != expected || (expected && value != want) {
					t.Fatalf("%s = %v (present %t), want %q (present %t)", field, value, present, want, expected)
				}
			}
		})
	}
}
