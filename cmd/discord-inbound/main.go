// discord-inbound publishes captain Discord messages onto JetStream and exits
// the wait: it does not call firstmate.
package main

import (
	"encoding/json"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/bwmarrin/discordgo"
	"github.com/mfreeman451/firstmate-port/internal/natsutil"
	"github.com/nats-io/nats.go"
)

func main() {
	token := os.Getenv("DISCORD_BOT_TOKEN")
	channelID := os.Getenv("DISCORD_CHANNEL_ID")
	stream := getenv("NATS_STREAM", "captain-inbound")
	subject := getenv("NATS_SUBJECT", "firstmate.discord.inbound")
	server := getenv("NATS_URL", nats.DefaultURL)
	if token == "" || channelID == "" {
		log.Fatal("DISCORD_BOT_TOKEN and DISCORD_CHANNEL_ID are required")
	}

	nc, err := natsutil.Connect(server, "discord-inbound")
	if err != nil {
		log.Fatal(err)
	}
	defer nc.Drain()
	js, err := nc.JetStream()
	if err != nil {
		log.Fatal(err)
	}
	if err := natsutil.EnsureStream(js, stream, []string{subject}); err != nil {
		log.Fatal(err)
	}

	dg, err := discordgo.New("Bot " + token)
	if err != nil {
		log.Fatal(err)
	}
	dg.Identify.Intents = discordgo.IntentsGuildMessages | discordgo.IntentMessageContent
	dg.AddHandler(func(s *discordgo.Session, m *discordgo.MessageCreate) {
		if m.Author == nil || m.Author.Bot {
			return
		}
		if m.ChannelID != channelID {
			return
		}
		payload, _ := json.Marshal(map[string]string{
			"id":         m.ID,
			"author":     m.Author.Username,
			"author_id":  m.Author.ID,
			"channel_id": m.ChannelID,
			"content":    m.Content,
			"url":        messageURL(m),
		})
		if _, err := js.Publish(subject, payload); err != nil {
			log.Printf("publish: %v", err)
		}
	})
	if err := dg.Open(); err != nil {
		log.Fatal(err)
	}
	defer dg.Close()
	log.Printf("discord-inbound streaming to %s %s", stream, subject)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
}

func messageURL(m *discordgo.MessageCreate) string {
	if m.GuildID == "" {
		return m.ID
	}
	return "https://discord.com/channels/" + m.GuildID + "/" + m.ChannelID + "/" + m.ID
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
