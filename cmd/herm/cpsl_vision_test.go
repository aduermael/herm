package main

import (
	"encoding/base64"
	"encoding/json"
	"testing"

	"langdag.com/langdag/types"
)

func TestCPSLVisionReadSendsMultimodalBlocksToConfiguredModel(t *testing.T) {
	client := newTestClient("read result")
	defer client.Close()
	service := &cpslVisionService{client: client, model: "xai/grok-4.5"}

	result, err := service.Read([]cpslVisionInput{
		{Data: []byte{1, 2, 3}, Filename: "page.png", MediaType: "image/png"},
		{Data: []byte("notes"), Filename: "notes.txt", MediaType: "text/plain"},
	}, "Extract the text")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if result != "read result" {
		t.Fatalf("result = %q", result)
	}

	provider := client.Provider().(*mockProvider)
	provider.mu.Lock()
	request := provider.lastRequest
	provider.mu.Unlock()
	if request == nil || request.Model != "xai/grok-4.5" || len(request.Messages) != 1 {
		t.Fatalf("request = %#v", request)
	}
	var blocks []types.ContentBlock
	if err := json.Unmarshal(request.Messages[0].Content, &blocks); err != nil {
		t.Fatalf("decode content blocks: %v", err)
	}
	if len(blocks) != 3 || blocks[0].Type != "text" || blocks[0].Text != "Extract the text" {
		t.Fatalf("blocks = %#v", blocks)
	}
	if blocks[1].Type != "image" || blocks[1].MediaType != "image/png" || blocks[1].Data != base64.StdEncoding.EncodeToString([]byte{1, 2, 3}) {
		t.Fatalf("image block = %#v", blocks[1])
	}
	if blocks[2].Type != "text" || blocks[2].Text != "notes" {
		t.Fatalf("text block = %#v", blocks[2])
	}
}

func TestCPSLVisionReadRequiresConfiguration(t *testing.T) {
	if _, err := (&cpslVisionService{}).Read(nil, "read"); err == nil {
		t.Fatal("Read without configuration returned nil error")
	}
}
