package fmsteer

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
)

// CmdInbox dispatches inbox put|next|ack|list.
func CmdInbox(args []string) int {
	if len(args) < 1 {
		return Usage()
	}
	switch args[0] {
	case "put":
		InboxPut(args[1:])
	case "next":
		InboxNext(args[1:])
	case "ack":
		InboxAck(args[1:])
	case "list":
		InboxList(args[1:])
	default:
		return Usage()
	}
	return 0
}

// InboxPut enqueues a message for a task; the body comes from --body or stdin.
func InboxPut(args []string) {
	fs := flag.NewFlagSet("put", flag.ExitOnError)
	task := fs.String("task", "", "task id (required)")
	bodyFlag := fs.String("body", "", "body; stdin if omitted")
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
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
	c := MustCreds(*instance)
	var out map[string]any
	if err := PostJSON(c.Instance+"/api/cli/inbox/put", c.Token, map[string]string{"task": *task, "body": body}, &out); err != nil {
		log.Fatal(err)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(out)
}

// InboxNext dequeues the next message for a task.
func InboxNext(args []string) {
	fs := flag.NewFlagSet("next", flag.ExitOnError)
	task := fs.String("task", "", "task id")
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	c := MustCreds(*instance)
	var out map[string]any
	status, err := PostJSONStatus(c.Instance+"/api/cli/inbox/next", c.Token, map[string]string{"task": *task}, &out)
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

// InboxAck acknowledges a message dequeued by next.
func InboxAck(args []string) {
	fs := flag.NewFlagSet("ack", flag.ExitOnError)
	ack := fs.String("ack", "", "ack token from next")
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	if *ack == "" {
		log.Fatal("ack requires --ack")
	}
	c := MustCreds(*instance)
	var out map[string]any
	if err := PostJSON(c.Instance+"/api/cli/inbox/ack", c.Token, map[string]string{"ack": *ack}, &out); err != nil {
		log.Fatal(err)
	}
	fmt.Println("acked")
}

// InboxList lists queued messages, optionally filtered by task.
func InboxList(args []string) {
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	task := fs.String("task", "", "optional task id")
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	_ = fs.Parse(args)
	c := MustCreds(*instance)
	url := c.Instance + "/api/cli/inbox"
	if *task != "" {
		url += "?task=" + *task
	}
	var out map[string]any
	if err := GetJSON(url, c.Token, &out); err != nil {
		log.Fatal(err)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(out)
}
