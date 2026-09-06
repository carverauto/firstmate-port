package fmsteer

import (
	"flag"
	"log"
	"os"
	"strconv"
	"strings"
)

// QueuePath is the portal's queue look-in endpoint. Posting here is how a
// crewmate reports what it was handed; fm-steer never dials NATS, the API
// fans the fact out.
const QueuePath = "/api/queues"

func cmdQueue(args []string) {
	if len(args) < 1 {
		os.Exit(Usage())
	}
	switch args[0] {
	case "post":
		queuePost(args[1:])
	case "list":
		queueList(args[1:])
	default:
		os.Exit(Usage())
	}
}

// queuePost reports one queue fact. Every field but --task is optional and
// sparse: the portal merges a report onto what it already tracks, so a worker
// can send the model up front and the token totals when it finishes.
func queuePost(args []string) {
	fs := flag.NewFlagSet("queue post", flag.ExitOnError)
	task := fs.String("task", "", "task id (required)")
	worker := fs.String("worker", "", "crewmate the task went to")
	agentID := fs.String("agent-id", "", "agent id running the task")
	status := fs.String("status", "", "queued|working|needs-decision|blocked|paused|done|failed")
	model := fs.String("model", "", "model the worker runs")
	effort := fs.String("effort", "", "reasoning effort the worker runs at")
	summary := fs.String("summary", "", "one line describing the work")
	tokensIn := fs.String("tokens-in", "", "cumulative input tokens")
	tokensOut := fs.String("tokens-out", "", "cumulative output tokens")
	startedAt := fs.String("started-at", "", "RFC3339 start time (defaults to first report)")
	stoppedAt := fs.String("stopped-at", "", "RFC3339 stop time (defaults to the terminal report)")
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	if *task == "" {
		log.Fatal("queue post requires --task")
	}
	payload := map[string]any{"task": *task}
	setIf(payload, "worker", *worker)
	setIf(payload, "agent_id", *agentID)
	setIf(payload, "status", *status)
	setIf(payload, "model", *model)
	setIf(payload, "effort", *effort)
	setIf(payload, "summary", *summary)
	setIfCount(payload, "tokens_in", *tokensIn)
	setIfCount(payload, "tokens_out", *tokensOut)
	setIf(payload, "started_at", *startedAt)
	setIf(payload, "stopped_at", *stoppedAt)
	postIngest(QueuePath, *instance, payload)
}

// queueList reads the tenant's in-flight work back. The look-in is ephemeral,
// so this shows the present, not a history.
func queueList(args []string) {
	fs := flag.NewFlagSet("queue list", flag.ExitOnError)
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	base, token := endpointAuth(*instance)
	var out map[string]any
	// GetJSON already turns a non-2xx into an error carrying the portal's own
	// `error` field, so a refused read is never mistaken for an empty look-in.
	if err := GetJSON(base+QueuePath, token, &out); err != nil {
		log.Fatal(err)
	}
	printJSON(out)
}

// setIfCount records a counter only when the flag was actually given. An empty
// flag is "unreported", not zero: zero tokens is a real report, and the portal
// merges what it is sent onto what it already tracks.
func setIfCount(payload map[string]any, key, value string) {
	if value == "" {
		return
	}
	count, err := strconv.Atoi(value)
	if err != nil || count < 0 {
		log.Fatalf("--%s takes a non-negative whole number, got %q", strings.ReplaceAll(key, "_", "-"), value)
	}
	payload[key] = count
}
