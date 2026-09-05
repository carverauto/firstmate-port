package fmsteer

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"
)

// CmdAuth dispatches auth login|status|logout.
func CmdAuth(args []string) int {
	if len(args) < 1 {
		return Usage()
	}
	switch args[0] {
	case "login":
		AuthLogin(args[1:])
	case "status":
		AuthStatus(args[1:])
	case "logout":
		AuthLogout(args[1:])
	default:
		return Usage()
	}
	return 0
}

// AuthLogin runs the OAuth device-code flow and stores the token.
func AuthLogin(args []string) {
	fs := flag.NewFlagSet("login", flag.ExitOnError)
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", "http://localhost:4000"), "API base URL")
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
	if err := PostJSON(base+"/api/cli/auth/device", "", map[string]string{"client_id": "fm-steer"}, &issued); err != nil {
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
		status, err := PostJSONStatus(base+"/api/cli/auth/token", "", map[string]string{
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
		if err := WriteCreds(base, tok.AccessToken, tok.Tenant); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("Authenticated. Token stored at %s\n", CredsPath())
		return
	}
	log.Fatal("device code expired")
}

// AuthStatus prints the stored instance and tenant.
func AuthStatus(args []string) {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	c, err := ReadCreds()
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

// AuthLogout deletes the stored credentials.
func AuthLogout(args []string) {
	_ = flag.NewFlagSet("logout", flag.ExitOnError).Parse(args)
	path := CredsPath()
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		log.Fatal(err)
	}
	fmt.Println("logged out")
}
