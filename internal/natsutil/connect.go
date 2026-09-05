// Package natsutil is shared NATS connect + stream ensure for firstmate CLIs.
package natsutil

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/nats-io/nats.go"
)

// Connect dials NATS. NATS_TOKEN is required against the cluster; anonymous
// clients must not be able to publish <tenant>.steer.* or <tenant>.assign.*.
func Connect(server, name string) (*nats.Conn, error) {
	opts := []nats.Option{nats.Name(name)}
	if tok := os.Getenv("NATS_TOKEN"); tok != "" {
		opts = append(opts, nats.Token(tok))
	}
	return nats.Connect(server, opts...)
}

// Replicas is 3 on the firstmate cluster. Override with NATS_REPLICAS for a
// local one-node server.
func Replicas() int {
	if v := os.Getenv("NATS_REPLICAS"); v != "" {
		n, err := strconv.Atoi(v)
		if err == nil && n > 0 {
			return n
		}
	}
	return 3
}

// EnsureStream creates a FileStorage stream if missing. Subjects must be unique.
// Existing streams are left alone so we never overlap <tenant>.steer and
// <tenant>.inbound.
func EnsureStream(js nats.JetStreamContext, name string, subjects []string) error {
	subjects = unique(subjects)
	if len(subjects) == 0 {
		return fmt.Errorf("stream %s needs at least one subject", name)
	}
	_, err := js.AddStream(&nats.StreamConfig{
		Name:      name,
		Subjects:  subjects,
		Storage:   nats.FileStorage,
		Replicas:  Replicas(),
		Retention: nats.LimitsPolicy,
	})
	if err == nil {
		return nil
	}
	if _, infoErr := js.StreamInfo(name); infoErr == nil {
		return nil
	}
	return err
}

func unique(in []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}
