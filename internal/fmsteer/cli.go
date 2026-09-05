// Package fmsteer implements the fm-steer CLI: device-code auth and
// inbox commands against the firstmate-port HTTP API.
//
// It must not dial NATS JetStream; Discord inbound stays in Phoenix.
package fmsteer

import (
	"fmt"
	"os"
)

// DefaultInstance is the live portal. Local compose needs an explicit
// --instance http://localhost:4000 (or FIRSTMATE_INSTANCE).
const DefaultInstance = "https://firstmate.carverauto.dev"

// DefaultTask is the task a bare `inbox put` files under: a message for
// firstmate, not a crew item.
const DefaultTask = "firstmate"

// Run dispatches the fm-steer subcommands and returns the process exit
// code. main.go passes it straight to os.Exit.
func Run(args []string) int {
	if len(args) < 1 {
		return Usage()
	}
	switch args[0] {
	case "auth":
		return CmdAuth(args[1:])
	case "inbox":
		return CmdInbox(args[1:])
	default:
		return Usage()
	}
}

// Usage prints the CLI synopsis and returns the conventional exit code 2.
func Usage() int {
	fmt.Fprintf(os.Stderr, "usage: fm-steer auth login|status|logout | inbox put|next|ack|list\n")
	return 2
}
