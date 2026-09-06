package fmsteer

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// Creds is the stored device-code credential set.
type Creds struct {
	Instance string `json:"instance"`
	Token    string `json:"token"`
	Tenant   string `json:"tenant"`
}

// CredsDir returns the directory holding credentials.json.
func CredsDir() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "fm-steer")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "fm-steer")
}

// CredsPath returns the credentials file path.
func CredsPath() string {
	return filepath.Join(CredsDir(), "credentials.json")
}

// WriteCreds stores the credential set with mode 0600.
func WriteCreds(instance, token, tenant string) error {
	dir := CredsDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := CredsPath()
	raw, err := json.MarshalIndent(Creds{Instance: instance, Token: token, Tenant: tenant}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

// ReadCreds loads the stored credential set.
func ReadCreds() (Creds, error) {
	raw, err := os.ReadFile(CredsPath())
	if err != nil {
		return Creds{}, err
	}
	var c Creds
	err = json.Unmarshal(raw, &c)
	return c, err
}

// MustCreds loads credentials or exits; an explicit instance overrides
// the stored one.
func MustCreds(instance string) Creds {
	c, err := ReadCreds()
	if err != nil || c.Token == "" {
		log.Fatal("not logged in; run fm-steer auth login")
	}
	if instance != "" {
		c.Instance = strings.TrimRight(instance, "/")
	}
	return c
}

// Env returns os.Getenv(k), falling back to d when unset or empty.
func Env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
