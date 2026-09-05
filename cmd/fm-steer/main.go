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
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, "usage: fm-steer auth login|status|logout | inbox put|next|ack|list\n")
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
		status, err := postJSONStatus(base+"/api/cli/auth/token", "", map[string]string{
			"grant_type":  "urn:ietf:params:oauth:grant-type:device_code",
			"device_code": issued.DeviceCode,
		}, &tok)
		if err != nil {
			log.Fatal(err)
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
	raw, err := json.Marshal(body)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return 0, err
	}
	req.Header.Set("content-type", "application/json")
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if out != nil && len(b) > 0 {
		_ = json.Unmarshal(b, out)
	}
	if resp.StatusCode >= 500 {
		return resp.StatusCode, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return resp.StatusCode, nil
}

func getJSON(url, token string, out any) error {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(out)
}
