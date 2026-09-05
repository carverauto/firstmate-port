// fm-steer talks only to the firstmate-port HTTP API.
// It must not dial NATS JetStream.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	log.SetFlags(0)
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "auth":
		cmdAuth(os.Args[2:])
	case "inbox":
		cmdInbox(os.Args[2:])
	case "route":
		routeRun(os.Args[2:])
	case "usage":
		usageRun(os.Args[2:])
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, "usage: fm-steer auth login|status|logout | inbox put|next|ack|list | route \"<task>\" | usage [--sync]\n")
	os.Exit(2)
}

func cmdAuth(args []string) {
	if len(args) < 1 {
		usage()
	}
	switch args[0] {
	case "login":
		authLogin(args[1:])
	case "status":
		authStatus(args[1:])
	case "logout":
		authLogout(args[1:])
	default:
		usage()
	}
}

func cmdInbox(args []string) {
	if len(args) < 1 {
		usage()
	}
	switch args[0] {
	case "put":
		inboxPut(args[1:])
	case "next":
		inboxNext(args[1:])
	case "ack":
		inboxAck(args[1:])
	case "list":
		inboxList(args[1:])
	default:
		usage()
	}
}

func authLogin(args []string) {
	fs := flag.NewFlagSet("login", flag.ExitOnError)
	instance := fs.String("instance", env("FIRSTMATE_INSTANCE", "http://localhost:4000"), "API base URL")
	_ = fs.Parse(args)
	base := strings.TrimRight(*instance, "/")

	var issued struct {
		DeviceCode              string `json:"device_code"`
		UserCode                string `json:"user_code"`
		VerificationURI         string `json:"verification_uri"`
		VerificationURIComplete string `json:"verification_uri_complete"`
		ExpiresIn               int    `json:"expires_in"`
		Interval                int    `json:"interval"`
	}
	if err := postJSON(base+"/api/cli/auth/device", "", map[string]string{"client_id": "fm-steer"}, &issued); err != nil {
		log.Fatal(err)
	}
	uri := issued.VerificationURIComplete
	if uri == "" {
		uri = issued.VerificationURI
	}
	fmt.Printf("Open this URL:\n  %s\n", uri)
	if issued.UserCode != "" {
		fmt.Printf("Code: %s\n", issued.UserCode)
	}

	interval := issued.Interval
	if interval < 1 {
		interval = 5
	}
	deadline := time.Now().Add(time.Duration(issued.ExpiresIn) * time.Second)
	if issued.ExpiresIn == 0 {
		deadline = time.Now().Add(10 * time.Minute)
	}
	for time.Now().Before(deadline) {
		time.Sleep(time.Duration(interval) * time.Second)
		var tok struct {
			AccessToken string `json:"access_token"`
			Error       string `json:"error"`
			Tenant      string `json:"tenant"`
		}
		status, raw, err := requestJSON(http.MethodPost, base+"/api/cli/auth/token", "", map[string]string{
			"grant_type":  "urn:ietf:params:oauth:grant-type:device_code",
			"device_code": issued.DeviceCode,
		}, &tok)
		if err != nil {
			log.Fatal(err)
		}
		if status >= 400 && status != http.StatusBadRequest {
			log.Fatal(statusError(status, raw))
		}
		if tok.Error == "authorization_pending" || status == 400 && tok.AccessToken == "" && tok.Error == "" {
			continue
		}
		if tok.Error == "slow_down" {
			interval += 5
			continue
		}
		if tok.Error == "access_denied" || tok.Error == "expired_token" {
			log.Fatal(tok.Error)
		}
		if tok.AccessToken == "" {
			continue
		}
		if err := writeCreds(base, tok.AccessToken, tok.Tenant); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("Authenticated. Token stored at %s\n", credsPath())
		return
	}
	log.Fatal("device code expired")
}

func authStatus(args []string) {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	instance := fs.String("instance", env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	c, err := readCreds()
	if err != nil || c.Token == "" {
		fmt.Println("not logged in")
		os.Exit(1)
	}
	inst := *instance
	if inst == "" {
		inst = c.Instance
	}
	fmt.Printf("instance %s\ntenant %s\n", inst, c.Tenant)
}

func authLogout(args []string) {
	_ = flag.NewFlagSet("logout", flag.ExitOnError).Parse(args)
	path := credsPath()
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		log.Fatal(err)
	}
	fmt.Println("logged out")
}

func inboxPut(args []string) {
	fs := flag.NewFlagSet("put", flag.ExitOnError)
	task := fs.String("task", "", "task id (required)")
	bodyFlag := fs.String("body", "", "body; stdin if omitted")
	instance := fs.String("instance", env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	if *task == "" {
		log.Fatal("put requires --task")
	}
	body := *bodyFlag
	if body == "" {
		raw, err := io.ReadAll(os.Stdin)
		if err != nil {
			log.Fatal(err)
		}
		body = string(raw)
	}
	c := mustCreds(*instance)
	var out map[string]any
	if err := postJSON(c.Instance+"/api/cli/inbox/put", c.Token, map[string]string{"task": *task, "body": body}, &out); err != nil {
		log.Fatal(err)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(out)
}

func inboxNext(args []string) {
	fs := flag.NewFlagSet("next", flag.ExitOnError)
	task := fs.String("task", "", "task id")
	instance := fs.String("instance", env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	c := mustCreds(*instance)
	var out map[string]any
	status, err := postJSONStatus(c.Instance+"/api/cli/inbox/next", c.Token, map[string]string{"task": *task}, &out)
	if err != nil {
		log.Fatal(err)
	}
	if status == 204 {
		os.Exit(1)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(out)
}

func inboxAck(args []string) {
	fs := flag.NewFlagSet("ack", flag.ExitOnError)
	ack := fs.String("ack", "", "ack token from next")
	instance := fs.String("instance", env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	if *ack == "" {
		log.Fatal("ack requires --ack")
	}
	c := mustCreds(*instance)
	var out map[string]any
	if err := postJSON(c.Instance+"/api/cli/inbox/ack", c.Token, map[string]string{"ack": *ack}, &out); err != nil {
		log.Fatal(err)
	}
	fmt.Println("acked")
}

func inboxList(args []string) {
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	task := fs.String("task", "", "optional task id")
	instance := fs.String("instance", env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	c := mustCreds(*instance)
	url := c.Instance + "/api/cli/inbox"
	if *task != "" {
		url += "?task=" + *task
	}
	var out map[string]any
	if err := getJSON(url, c.Token, &out); err != nil {
		log.Fatal(err)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(out)
}

type creds struct {
	Instance string `json:"instance"`
	Token    string `json:"token"`
	Tenant   string `json:"tenant"`
}

// routeRun asks the portal router which worker to use. All ranking lives
// server-side; this command only renders the answer.
func routeRun(args []string) {
	fs := flag.NewFlagSet("route", flag.ExitOnError)
	instance := fs.String("instance", env("FIRSTMATE_INSTANCE", ""), "API base URL")
	intel := fs.Bool("intel", false, "fold in live provider intel (OpenRouter / Artificial Analysis)")
	asJSON := fs.Bool("json", false, "print the full route response as JSON")
	_ = fs.Parse(args)

	description := strings.Join(fs.Args(), " ")
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
	c := mustCreds(*instance)
	var out routeResponse
	if err := postJSON(c.Instance+"/api/route", c.Token, map[string]any{
		"description": description,
		"intel":       *intel,
	}, &out); err != nil {
		log.Fatal(err)
	}
	if *asJSON {
		printJSON(out)
		return
	}
	display := out.ModelDisplay
	if display == "" {
		display = out.Model
	}
	fmt.Printf("harness %s\nmodel %s (%s)\neffort %s\n", out.Harness, display, out.Model, out.Effort)
	if out.Checkpoint != "" {
		fmt.Printf("checkpoint %s\n", out.Checkpoint)
	}
	for _, r := range out.Reasons {
		fmt.Printf("- %s\n", r)
	}
}

type routeResponse struct {
	Tenant       string         `json:"tenant"`
	Harness      string         `json:"harness"`
	Model        string         `json:"model"`
	ModelDisplay string         `json:"model_display"`
	ModelSource  string         `json:"model_source"`
	Effort       string         `json:"effort"`
	Reasons      []string       `json:"reasons"`
	Axes         map[string]any `json:"axes"`
	Intel        []string       `json:"intel_sources"`
	Checkpoint   string         `json:"checkpoint"`
}

// usageRun shows per-account token usage and remaining allowance from the
// portal ledger. With --sync it first refreshes syncable accounts through
// the portal (provider keys stay server-side). No quota math lives here.
func usageRun(args []string) {
	fs := flag.NewFlagSet("usage", flag.ExitOnError)
	instance := fs.String("instance", env("FIRSTMATE_INSTANCE", ""), "API base URL")
	sync := fs.Bool("sync", false, "refresh syncable accounts before listing")
	asJSON := fs.Bool("json", false, "print the full usage response as JSON")
	_ = fs.Parse(args)

	c := mustCreds(*instance)
	if *sync {
		var res usageSyncResponse
		if err := postJSON(c.Instance+"/api/usage/sync", c.Token, map[string]any{}, &res); err != nil {
			log.Fatal(err)
		}
		if !*asJSON {
			for _, r := range res.Data {
				mark := "ok"
				if !r.Synced {
					mark = "skip"
				}
				fmt.Printf("%s %s/%s: %s\n", mark, r.Account.Provider, r.Account.Label, r.Note)
			}
		}
	}
	var out usageResponse
	if err := getJSON(c.Instance+"/api/usage", c.Token, &out); err != nil {
		log.Fatal(err)
	}
	if *asJSON {
		printJSON(out)
		return
	}
	fmt.Printf("%-12s %-20s %12s %12s %12s %-6s %8s\n", "provider", "label", "allowance", "used", "remaining", "status", "runway")
	for _, a := range out.Data {
		fmt.Printf("%-12s %-20s %12s %12s %12s %-6s %8s\n",
			a.Provider, a.Label, numOrDash(a.Allowance), numOrDash(a.Used),
			numOrDash(a.Remaining), a.Status, runwayOrDash(a.RunwayDays))
	}
}

type usageAccount struct {
	Provider   string   `json:"provider"`
	Label      string   `json:"label"`
	Unit       string   `json:"unit"`
	Allowance  *float64 `json:"allowance"`
	Used       *float64 `json:"used"`
	Remaining  *float64 `json:"remaining"`
	Status     string   `json:"status"`
	RunwayDays *float64 `json:"runway_days"`
	Window     string   `json:"window"`
	Source     string   `json:"source"`
}

type usageResponse struct {
	Tenant string         `json:"tenant"`
	Data   []usageAccount `json:"data"`
}

type usageSyncResponse struct {
	Tenant string `json:"tenant"`
	Data   []struct {
		Account usageAccount `json:"account"`
		Synced  bool         `json:"synced"`
		Note    string       `json:"note"`
	} `json:"data"`
}

func numOrDash(f *float64) string {
	if f == nil {
		return "-"
	}
	return fmt.Sprintf("%.2f", *f)
}

func runwayOrDash(f *float64) string {
	if f == nil {
		return "-"
	}
	return fmt.Sprintf("%.1fd", *f)
}

func printJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func credsDir() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "fm-steer")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "fm-steer")
}

func credsPath() string {
	return filepath.Join(credsDir(), "credentials.json")
}

func writeCreds(instance, token, tenant string) error {
	dir := credsDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := credsPath()
	raw, err := json.MarshalIndent(creds{Instance: instance, Token: token, Tenant: tenant}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func readCreds() (creds, error) {
	raw, err := os.ReadFile(credsPath())
	if err != nil {
		return creds{}, err
	}
	var c creds
	err = json.Unmarshal(raw, &c)
	return c, err
}

func mustCreds(instance string) creds {
	c, err := readCreds()
	if err != nil || c.Token == "" {
		log.Fatal("not logged in; run fm-steer auth login")
	}
	if instance != "" {
		c.Instance = strings.TrimRight(instance, "/")
	}
	return c
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func postJSON(url, token string, body any, out any) error {
	_, err := postJSONStatus(url, token, body, out)
	return err
}

func postJSONStatus(url, token string, body any, out any) (int, error) {
	status, raw, err := requestJSON(http.MethodPost, url, token, body, out)
	if err != nil {
		return status, err
	}
	return status, statusError(status, raw)
}

func getJSON(url, token string, out any) error {
	status, raw, err := requestJSON(http.MethodGet, url, token, nil, out)
	if err != nil {
		return err
	}
	return statusError(status, raw)
}

// requestJSON reports transport and 2xx decode failures, and hands the status
// back raw, so the device-code poll loop can read RFC 8628's 400 as "pending".
func requestJSON(method, url, token string, body any, out any) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("content-type", "application/json")
	}
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil && resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return resp.StatusCode, raw, fmt.Errorf("%s: response was not JSON: %w", url, err)
		}
	}
	return resp.StatusCode, raw, nil
}

func statusError(status int, raw []byte) error {
	if status >= 200 && status < 300 {
		return nil
	}
	var body struct {
		Error string `json:"error"`
	}
	if len(raw) > 0 && json.Unmarshal(raw, &body) == nil && body.Error != "" {
		return fmt.Errorf("HTTP %d: %s", status, body.Error)
	}
	return fmt.Errorf("HTTP %d", status)
}
