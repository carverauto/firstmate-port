// nats-tail prints one JetStream message per line.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mfreeman451/firstmate-port/internal/natsutil"
	"github.com/nats-io/nats.go"
)

func main() {
	stream := flag.String("stream", "", "JetStream stream name (required)")
	subject := flag.String("subject", ">", "Filter subject within the stream")
	server := flag.String("server", env("NATS_URL", nats.DefaultURL), "NATS server URL")
	durable := flag.String("durable", "", "Durable consumer name (default: nats-tail-<stream>)")
	flag.Parse()
	if *stream == "" {
		log.Fatal("nats-tail: --stream is required")
	}
	if *durable == "" {
		*durable = "nats-tail-" + *stream
	}

	nc, err := natsutil.Connect(*server, "nats-tail")
	if err != nil {
		log.Fatal(err)
	}
	defer nc.Drain()
	js, err := nc.JetStream()
	if err != nil {
		log.Fatal(err)
	}

	opts := []nats.SubOpt{
		nats.BindStream(*stream),
		nats.ManualAck(),
		nats.DeliverAll(),
		nats.Durable(*durable),
		nats.AckExplicit(),
	}
	sub, err := js.Subscribe(*subject, func(msg *nats.Msg) {
		meta, _ := msg.Metadata()
		seq := uint64(0)
		if meta != nil {
			seq = meta.Sequence.Stream
		}
		fmt.Printf("%d %s %s\n", seq, msg.Subject, string(msg.Data))
		_ = msg.Ack()
	}, opts...)
	if err != nil {
		log.Fatal(err)
	}
	defer sub.Unsubscribe()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	time.Sleep(50 * time.Millisecond)
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
