package fmsteer

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"log"
	"os"
	"strings"
)

// AgentTokenEnv carries the agent API token for Fleet log writes.
const AgentTokenEnv = "FIRSTMATE_AGENT_TOKEN"

func cmdRolls(args []string) {
	if len(args) < 1 {
		os.Exit(Usage())
	}
	switch args[0] {
	case "post":
		rollsPost(args[1:])
	default:
		os.Exit(Usage())
	}
}

func cmdDiagrams(args []string) {
	if len(args) < 1 {
		os.Exit(Usage())
	}
	switch args[0] {
	case "post":
		diagramsPost(args[1:])
	default:
		os.Exit(Usage())
	}
}

func cmdNoMistakes(args []string) {
	if len(args) < 1 {
		os.Exit(Usage())
	}
	switch args[0] {
	case "post":
		noMistakesPost(args[1:])
	default:
		os.Exit(Usage())
	}
}

func rollsPost(args []string) {
	fs := flag.NewFlagSet("rolls post", flag.ExitOnError)
	cluster := fs.String("cluster", "", "cluster name (required)")
	namespace := fs.String("namespace", "", "namespace (required)")
	status := fs.String("status", "", "started|success|failure (required)")
	imageTag := fs.String("image-tag", "", "image tag (required)")
	prURL := fs.String("pr-url", "", "PR URL")
	issueURL := fs.String("issue-url", "", "issue URL")
	outcome := fs.String("outcome", "", "outcome notes")
	rebuilt := fs.String("rebuilt", "", "comma-separated rebuilt artifacts")
	copied := fs.String("copied", "", "comma-separated copied artifacts")
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	if *cluster == "" || *namespace == "" || *status == "" || *imageTag == "" {
		log.Fatal("rolls post requires --cluster, --namespace, --status, and --image-tag")
	}
	payload := map[string]any{
		"cluster":   *cluster,
		"namespace": *namespace,
		"status":    *status,
		"image_tag": *imageTag,
	}
	setIf(payload, "pr_url", *prURL)
	setIf(payload, "issue_url", *issueURL)
	setIf(payload, "outcome", *outcome)
	setList(payload, "rebuilt", *rebuilt)
	setList(payload, "copied", *copied)
	postIngest("/api/rolls", *instance, payload)
}

func diagramsPost(args []string) {
	fs := flag.NewFlagSet("diagrams post", flag.ExitOnError)
	id := fs.String("id", "", "diagram id (generated when omitted)")
	title := fs.String("title", "", "title")
	notes := fs.String("notes", "", "notes")
	htmlFile := fs.String("html-file", "", "HTML file to upload")
	pngFile := fs.String("png-file", "", "PNG file to upload")
	svgFile := fs.String("svg-file", "", "SVG file to upload")
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	payload := map[string]any{}
	setIf(payload, "id", *id)
	setIf(payload, "title", *title)
	setIf(payload, "notes", *notes)
	setIf(payload, "html_base64", fileB64(*htmlFile))
	setIf(payload, "png_base64", fileB64(*pngFile))
	setIf(payload, "svg_base64", fileB64(*svgFile))
	postIngest("/api/diagrams", *instance, payload)
}

func noMistakesPost(args []string) {
	fs := flag.NewFlagSet("no-mistakes post", flag.ExitOnError)
	runID := fs.String("run-id", "", "pipeline run id (required)")
	branch := fs.String("branch", "", "branch (required)")
	step := fs.String("step", "", "pipeline step")
	findings := fs.String("findings", "", "findings summary")
	prURL := fs.String("pr-url", "", "PR URL")
	outcome := fs.String("outcome", "", "outcome")
	intent := fs.String("intent", "", "run intent")
	publicSummary := fs.String("public-summary", "", "public summary")
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	if *runID == "" || *branch == "" {
		log.Fatal("no-mistakes post requires --run-id and --branch")
	}
	payload := map[string]any{"run_id": *runID, "branch": *branch}
	setIf(payload, "step", *step)
	setIf(payload, "findings", *findings)
	setIf(payload, "pr_url", *prURL)
	setIf(payload, "outcome", *outcome)
	setIf(payload, "intent", *intent)
	setIf(payload, "public_summary", *publicSummary)
	postIngest("/api/no-mistakes", *instance, payload)
}

// endpointAuth resolves the API host and credential for Fleet log ingest.
// An agent API token in FIRSTMATE_AGENT_TOKEN wins (ingest writes require an
// agent role); otherwise the device-code login credentials are used.
func endpointAuth(instance string) (string, string) {
	if t := strings.TrimSpace(os.GetEnv(AgentTokenEnv)); t != "" {
		base := strings.TrimRight(instance, "/")
		if base == "" {
			if c, err := ReadCreds(); err == nil && c.Instance != "" {
				base = c.Instance
			} else {
				base = DefaultInstance
			}
		}
		return base, t
	}
	c := MustCreds(instance)
	return c.Instance, c.Token
}

func postIngest(path, instance string, payload map[string]any) {
	base, token := endpointAuth(instance)
	var out map[string]any
	status, err := PostJSONStatus(base+path, token, payload, &out)
	if err != nil {
		log.Fatal(err)
	}
	switch {
	case status == 401 || status == 403:
		log.Fatalf("ingest write refused (HTTP %d): writes require an agent role; set %s to an agent API token", status, AgentTokenEnv)
	case status >= 400:
		log.Fatalf("ingest write failed: HTTP %d", status)
	}
	printJSON(out)
}

func printJSON(out map[string]any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(out)
}

func setIf(payload map[string]any, key, value string) {
	if value != "" {
		payload[key] = value
	}
}

func setList(payload map[string]any, key, value string) {
	if value == "" {
		return
	}
	var items []string
	for _, item := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(item); trimmed != "" {
			items = append(items, trimmed)
		}
	}
	if items != nil {
		payload[key] = items
	}
}

func fileB64(path string) string {
	if path == "" {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		log.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(raw)
}
