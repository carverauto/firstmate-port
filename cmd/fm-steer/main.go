// fm-steer talks only to the firstmate-port HTTP API.
// It must not dial NATS JetStream.
package main

import (
	"log"
	"os"

	"github.com/mfreeman451/firstmate-port/internal/fmsteer"
)

func main() {
	log.SetFlags(0)
	os.Exit(fmsteer.Run(os.Args[1:]))
}
