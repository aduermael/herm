// cpsl_vision.go adapts CPSL document inputs to Herm multimodal model requests.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"langdag.com/langdag"
	"langdag.com/langdag/types"
)

type cpslVisionInput struct {
	Data      []byte
	Filename  string
	MediaType string
}

type cpslVisionReadOptions struct {
	inputs []cpslVisionInput
	query  string
}

type cpslSessionVisionOptions struct {
	configJSON string
	handler    cpslVisionHandler
}

type cpslVisionHandler func(opts cpslVisionReadOptions) (string, error)

type cpslVisionService struct {
	mu     sync.Mutex
	client *langdag.Client
	model  string
}

func (s *cpslVisionService) Configure(config cpslVisionRuntimeConfig) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.client != nil {
		_ = s.client.Close()
		s.client = nil
	}
	s.model = ""
	if config.Model == "" {
		return nil
	}

	client, err := newLangdagClientWithCatalog(config.Config, config.Catalog)
	if err != nil {
		return err
	}
	if client == nil {
		return fmt.Errorf("vision model has no configured provider")
	}
	s.client = client
	s.model = config.Model
	return nil
}

func (s *cpslVisionService) Read(opts cpslVisionReadOptions) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client == nil || s.model == "" {
		return "", fmt.Errorf("vision model is not configured")
	}

	blocks := []types.ContentBlock{{Type: "text", Text: opts.query}}
	for _, input := range opts.inputs {
		switch {
		case strings.HasPrefix(input.MediaType, "image/"):
			blocks = append(blocks, types.ContentBlock{
				Type:      "image",
				MediaType: input.MediaType,
				Data:      base64.StdEncoding.EncodeToString(input.Data),
			})
		case input.MediaType == "text/plain" || input.MediaType == "text/markdown" || input.MediaType == "text/csv" || input.MediaType == "application/json" || input.MediaType == "text/html":
			blocks = append(blocks, types.ContentBlock{Type: "text", Text: string(input.Data)})
		default:
			blocks = append(blocks, types.ContentBlock{
				Type:      "document",
				MediaType: input.MediaType,
				Data:      base64.StdEncoding.EncodeToString(input.Data),
			})
		}
	}
	content, err := json.Marshal(blocks)
	if err != nil {
		return "", err
	}
	response, err := s.client.Provider().Complete(context.Background(), &types.CompletionRequest{
		Model:     s.model,
		Messages:  []types.Message{{Role: "user", Content: content}},
		MaxTokens: defaultMaxOutputTokens,
	})
	if err != nil {
		return "", err
	}

	var text []string
	for _, block := range response.Content {
		if block.Type == "text" && block.Text != "" {
			text = append(text, block.Text)
		}
	}
	if len(text) == 0 {
		return "", fmt.Errorf("vision model returned no text")
	}
	return strings.Join(text, ""), nil
}
