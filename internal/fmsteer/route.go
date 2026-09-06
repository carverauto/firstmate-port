package fmsteer

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
)

// RouteRun asks the portal router which worker to use. All ranking, the
// capability matrix and the quota ledger live server-side; this command
// only renders the answer.
func RouteRun(args []string) {
	fs := flag.NewFlagSet("route", flag.ExitOnError)
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	intel := fs.Bool("intel", false, "fold in live provider intel (Artificial Analysis)")
	asJSON := fs.Bool("json", false, "print the full route response as JSON")
	words := parseInterspersed(fs, args)

	description := strings.Join(words, " ")
	if description == "" {
		raw, err := io.ReadAll(os.Stdin)
		if err != nil {
			log.Fatal(err)
		}
		description = strings.TrimSpace(string(raw))
		if description == "" {
			log.Fatal("route requires a task description argument or stdin")
		}
	}
	c := MustCreds(*instance)
	var out RouteResponse
	if err := PostJSON(c.Instance+"/api/route", c.Token, map[string]any{
		"description": description,
		"intel":       *intel,
	}, &out); err != nil {
		log.Fatal(err)
	}
	if *asJSON {
		printJSONValue(out)
		return
	}
	display := out.ModelDisplay
	if display == "" {
		display = out.Model
	}
	fmt.Printf("harness %s\nmodel %s (%s)\neffort %s\n", out.Harness, display, out.Model, out.Effort)
	for _, r := range out.Reasons {
		fmt.Printf("- %s\n", r)
	}
}

// parseInterspersed parses flags wherever they appear and returns the
// positional words. Go's flag package stops at the first non-flag, which
// would otherwise fold a trailing --json into the task text.
func parseInterspersed(fs *flag.FlagSet, args []string) []string {
	var words []string
	rest := args

	for {
		_ = fs.Parse(rest)
		rest = fs.Args()
		if len(rest) == 0 {
			return words
		}
		words = append(words, rest[0])
		rest = rest[1:]
	}
}

// RouteResponse is the portal's routing answer. The fields mirror
// POST /api/route; the CLI never computes any of them.
type RouteResponse struct {
	Tenant       string         `json:"tenant"`
	Harness      string         `json:"harness"`
	Model        string         `json:"model"`
	ModelDisplay string         `json:"model_display"`
	ModelSource  string         `json:"model_source"`
	Effort       string         `json:"effort"`
	Reasons      []string       `json:"reasons"`
	Axes         map[string]any `json:"axes"`
	Intel        []string       `json:"intel_sources"`
}

// printJSONValue prints any value as a single JSON line.
func printJSONValue(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}
