package main

import (
	"strings"
	"testing"
)

func TestRenameMessage(t *testing.T) {
	if !strings.Contains(renameMsg, "firstmatectl") {
		t.Fatalf("got %q", renameMsg)
	}
}
