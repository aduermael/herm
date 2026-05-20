// request_cache.go caches successful provider responses for headless test runs.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"langdag.com/langdag"
	"langdag.com/langdag/types"
)

const requestCacheSchemaVersion = 1

type requestCacheProvider struct {
	inner        langdag.Provider
	dir          string
	configForKey Config
}

type requestCacheEntry struct {
	SchemaVersion int                       `json:"schema_version"`
	Key           string                    `json:"key"`
	Operation     string                    `json:"operation"`
	CreatedAt     time.Time                 `json:"created_at"`
	Response      *types.CompletionResponse `json:"response"`
}

type newRequestCacheProviderOptions struct {
	inner langdag.Provider
	dir   string
	cfg   Config
}

func newRequestCacheProvider(opts newRequestCacheProviderOptions) (*requestCacheProvider, error) {
	dir := expandHomePath(strings.TrimSpace(opts.dir))
	if dir == "" {
		return nil, fmt.Errorf("request cache directory is empty")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("creating request cache directory: %w", err)
	}
	_ = os.Chmod(dir, 0o700)
	return &requestCacheProvider{inner: opts.inner, dir: dir, configForKey: opts.cfg}, nil
}

func (p *requestCacheProvider) Name() string {
	return p.inner.Name()
}

func (p *requestCacheProvider) Models() []types.ModelInfo {
	return p.inner.Models()
}

func (p *requestCacheProvider) Complete(ctx context.Context, req *types.CompletionRequest) (*types.CompletionResponse, error) {
	key, err := p.cacheKey(requestCacheKeyOptions{operation: "complete", req: req})
	if err == nil {
		if entry, ok := p.read(requestCacheReadOptions{key: key, operation: "complete"}); ok {
			return cloneCompletionResponse(entry.Response), nil
		}
	}
	resp, err := p.inner.Complete(ctx, req)
	if err != nil {
		return nil, err
	}
	if key != "" && cacheableCompletionResponse(resp) {
		p.write(requestCacheWriteOptions{key: key, operation: "complete", resp: resp})
	}
	return resp, nil
}

func (p *requestCacheProvider) Stream(ctx context.Context, req *types.CompletionRequest) (<-chan types.StreamEvent, error) {
	key, err := p.cacheKey(requestCacheKeyOptions{operation: "stream", req: req})
	if err == nil {
		if entry, ok := p.read(requestCacheReadOptions{key: key, operation: "stream"}); ok {
			return replayCachedStream(replayCachedStreamOptions{ctx: ctx, resp: entry.Response}), nil
		}
	}

	innerCh, err := p.inner.Stream(ctx, req)
	if err != nil {
		return nil, err
	}
	out := make(chan types.StreamEvent, 100)
	go func() {
		defer close(out)
		var finalResponse *types.CompletionResponse
		var completed bool
		for event := range innerCh {
			if event.Type == types.StreamEventDone {
				finalResponse = cloneCompletionResponse(event.Response)
				completed = true
			}
			if event.Type == types.StreamEventError {
				completed = false
			}
			select {
			case <-ctx.Done():
				return
			case out <- event:
			}
		}
		if completed && key != "" && cacheableCompletionResponse(finalResponse) {
			p.write(requestCacheWriteOptions{key: key, operation: "stream", resp: finalResponse})
		}
	}()
	return out, nil
}

type requestCacheKeyOptions struct {
	operation string
	req       *types.CompletionRequest
}

func (p *requestCacheProvider) cacheKey(opts requestCacheKeyOptions) (string, error) {
	envelope := struct {
		SchemaVersion int                      `json:"schema_version"`
		Operation     string                   `json:"operation"`
		Provider      string                   `json:"provider"`
		Config        Config                   `json:"config"`
		Request       *types.CompletionRequest `json:"request"`
	}{
		SchemaVersion: requestCacheSchemaVersion,
		Operation:     opts.operation,
		Provider:      p.inner.Name(),
		Config:        sanitizeConfigForCacheKey(p.configForKey),
		Request:       canonicalCompletionRequest(opts.req),
	}
	data, err := json.Marshal(envelope)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

type requestCacheReadOptions struct {
	key       string
	operation string
}

func (p *requestCacheProvider) read(opts requestCacheReadOptions) (requestCacheEntry, bool) {
	var entry requestCacheEntry
	data, err := os.ReadFile(filepath.Join(p.dir, opts.key))
	if err != nil {
		return entry, false
	}
	if err := json.Unmarshal(data, &entry); err != nil {
		return requestCacheEntry{}, false
	}
	if entry.SchemaVersion != requestCacheSchemaVersion || entry.Key != opts.key || entry.Operation != opts.operation || entry.Response == nil {
		return requestCacheEntry{}, false
	}
	return entry, true
}

type requestCacheWriteOptions struct {
	key       string
	operation string
	resp      *types.CompletionResponse
}

func (p *requestCacheProvider) write(opts requestCacheWriteOptions) {
	entry := requestCacheEntry{
		SchemaVersion: requestCacheSchemaVersion,
		Key:           opts.key,
		Operation:     opts.operation,
		CreatedAt:     time.Now().UTC(),
		Response:      cloneCompletionResponse(opts.resp),
	}
	data, err := json.MarshalIndent(entry, "", "  ")
	if err != nil {
		return
	}
	tmp, err := os.CreateTemp(p.dir, "."+opts.key+"-*.tmp")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return
	}
	if _, err := tmp.Write([]byte("\n")); err != nil {
		_ = tmp.Close()
		return
	}
	if err := tmp.Close(); err != nil {
		return
	}
	_ = os.Chmod(tmpName, 0o600)
	_ = os.Rename(tmpName, filepath.Join(p.dir, opts.key))
}

type replayCachedStreamOptions struct {
	ctx  context.Context
	resp *types.CompletionResponse
}

func replayCachedStream(opts replayCachedStreamOptions) <-chan types.StreamEvent {
	out := make(chan types.StreamEvent, 100)
	go func() {
		defer close(out)
		for _, block := range opts.resp.Content {
			block := cloneContentBlock(block)
			var event types.StreamEvent
			if block.Type == "text" {
				if block.Text == "" {
					continue
				}
				event = types.StreamEvent{Type: types.StreamEventDelta, Content: block.Text}
			} else {
				event = types.StreamEvent{Type: types.StreamEventContentDone, ContentBlock: &block}
			}
			select {
			case <-opts.ctx.Done():
				return
			case out <- event:
			}
		}
		select {
		case <-opts.ctx.Done():
			return
		case out <- types.StreamEvent{Type: types.StreamEventDone, Response: cloneCompletionResponse(opts.resp)}:
		}
	}()
	return out
}

func cacheableCompletionResponse(resp *types.CompletionResponse) bool {
	return resp != nil && resp.StopReason != "max_tokens"
}

func canonicalCompletionRequest(req *types.CompletionRequest) *types.CompletionRequest {
	if req == nil {
		return nil
	}
	clone := *req
	if req.Messages != nil {
		clone.Messages = make([]types.Message, len(req.Messages))
		for i, msg := range req.Messages {
			clone.Messages[i] = msg
			clone.Messages[i].Content = canonicalRawJSON(msg.Content)
		}
	}
	if req.Tools != nil {
		clone.Tools = make([]types.ToolDefinition, len(req.Tools))
		for i, tool := range req.Tools {
			clone.Tools[i] = tool
			clone.Tools[i].InputSchema = canonicalRawJSON(tool.InputSchema)
		}
	}
	if req.StopSeqs != nil {
		clone.StopSeqs = append([]string(nil), req.StopSeqs...)
	}
	return &clone
}

func canonicalRawJSON(raw json.RawMessage) json.RawMessage {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return nil
	}
	var v any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		return append(json.RawMessage(nil), raw...)
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return append(json.RawMessage(nil), raw...)
	}
	data, err := json.Marshal(v)
	if err != nil {
		return append(json.RawMessage(nil), raw...)
	}
	return data
}

func cloneCompletionResponse(resp *types.CompletionResponse) *types.CompletionResponse {
	if resp == nil {
		return nil
	}
	data, err := json.Marshal(resp)
	if err != nil {
		cp := *resp
		cp.Content = cloneContentBlocks(resp.Content)
		return &cp
	}
	var out types.CompletionResponse
	if err := json.Unmarshal(data, &out); err != nil {
		cp := *resp
		cp.Content = cloneContentBlocks(resp.Content)
		return &cp
	}
	return &out
}

func cloneContentBlocks(blocks []types.ContentBlock) []types.ContentBlock {
	if blocks == nil {
		return nil
	}
	out := make([]types.ContentBlock, len(blocks))
	for i, block := range blocks {
		out[i] = cloneContentBlock(block)
	}
	return out
}

func cloneContentBlock(block types.ContentBlock) types.ContentBlock {
	block.Input = cloneRawMessage(block.Input)
	block.ContentJSON = cloneRawMessage(block.ContentJSON)
	block.ProviderData = cloneRawMessage(block.ProviderData)
	return block
}

func cloneRawMessage(raw json.RawMessage) json.RawMessage {
	if raw == nil {
		return nil
	}
	return append(json.RawMessage(nil), raw...)
}

func sanitizeConfigForCacheKey(cfg Config) Config {
	cfg.RequestCacheDir = ""
	cfg.AnthropicAPIKey = secretCacheFingerprint(cfg.AnthropicAPIKey)
	cfg.GrokAPIKey = secretCacheFingerprint(cfg.GrokAPIKey)
	cfg.OpenRouterAPIKey = secretCacheFingerprint(cfg.OpenRouterAPIKey)
	cfg.OpenAIAPIKey = secretCacheFingerprint(cfg.OpenAIAPIKey)
	cfg.GeminiAPIKey = secretCacheFingerprint(cfg.GeminiAPIKey)
	if cfg.Deployments != nil {
		deployments := make(map[string]DeploymentConfig, len(cfg.Deployments))
		for id, deployment := range cfg.Deployments {
			deployment = cloneDeploymentConfig(deployment)
			deployment.APIKey = secretCacheFingerprint(deployment.APIKey)
			deployments[id] = deployment
		}
		cfg.Deployments = deployments
	}
	return cfg
}

func secretCacheFingerprint(secret string) string {
	if secret == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(secret))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func expandHomePath(path string) string {
	if path == "" || path[0] != '~' {
		return path
	}
	if len(path) > 1 && path[1] != '/' {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	if len(path) == 1 {
		return home
	}
	return filepath.Join(home, path[2:])
}
