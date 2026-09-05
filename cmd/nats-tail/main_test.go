package main

import "testing"

func TestEnvFallback(t *testing.T) {
	t.Setenv("NATS_URL", "nats://example:4222")
	if env("NATS_URL", "x") != "nats://example:4222" {
		t.Fatal("env should prefer NATS_URL")
	}
	t.Setenv("NATS_URL", "")
	if env("MISSING_NATS", "nats://127.0.0.1:4222") != "nats://127.0.0.1:4222" {
		t.Fatal("env should use fallback")
	}
}
