// Package fmsteer implements the fm-steer CLI: device-code auth and
// inbox commands against the firstmate-port HTTP API.
//
// It must not dial NATS JetStream; Discord inbound stays in Phoenix.
package fmsteer

import (
	"fmt"
	"os"
)

// DefaultInstance is the local API; set --instance or FIRSTMATE_INSTANCE
// to use a deployed portal.
const DefaultInstance = "http://localhost:4000"

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
	case "rolls":
		cmdRolls(args[1:])
	case "diagrams":
		cmdDiagrams(args[1:])
	case "no-mistakes":
		cmdNoMistakes(args[1:])
	default:
		return Usage()
	}
	return 0
}

// Usage prints the CLI synopsis and returns the conventional exit code 2.
func Usage() int {
	fmt.Fprintf(os.Stderr, "usage: fm-steer auth login|status|logout | inbox put|next|ack|list\n")
	fmt.Fprintf(os.Stderr, "       fm-steer rolls|diagrams|no-mistakes post\n")
	fmt.Fprintf(os.Stderr, "ingest writes require an agent role: set %s to an agent API token.\n", AgentTokenEnv)
	return 2
}
