package natsutil

import "testing"

func TestUniqueDropsDuplicateSubjects(t *testing.T) {
	got := unique([]string{"local.discord.inbound", "local.discord.inbound", " local.discord.inbound "})
	if len(got) != 1 || got[0] != "local.discord.inbound" {
		t.Fatalf("got %v", got)
	}
}

func TestReplicasDefault(t *testing.T) {
	t.Setenv("NATS_REPLICAS", "")
	if Replicas() != 3 {
		t.Fatalf("default replicas want 3 got %d", Replicas())
	}
	t.Setenv("NATS_REPLICAS", "1")
	if Replicas() != 1 {
		t.Fatal("NATS_REPLICAS override")
	}
}
