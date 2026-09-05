// fm-steer was renamed to firstmatectl. Inbox traffic goes through the HTTP API.
package main

import (
	"fmt"
	"os"
)

const renameMsg = "fm-steer is now firstmatectl. Inbox put/next/ack/list go through the Phoenix API; this binary does not dial NATS."

func main() {
	fmt.Fprintln(os.Stderr, renameMsg)
	fmt.Fprintln(os.Stderr, "usage: firstmatectl auth login|status|logout | inbox put|next|ack|list")
	os.Exit(2)
}
