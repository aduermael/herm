// headless.go runs one-shot non-interactive prompts and prints resume IDs.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

// RunHeadless submits the --prompt text, waits for the agent, and exits.
func (a *App) RunHeadless() error {
	a.rebuildEffectiveConfig()
	a.startInit()

	if err := a.waitHeadlessReady(); err != nil {
		return err
	}
	if err := a.resolveHeadlessContinuation(); err != nil {
		return err
	}
	a.printHeadlessDebugPath()
	if err := a.startHeadlessAgent(); err != nil {
		return err
	}
	a.drainHeadlessAgent()
	a.printHeadlessAssistantOutput()
	a.printHeadlessConversationIDs()
	hasError := a.printHeadlessErrors()

	a.cleanup()
	if hasError {
		return fmt.Errorf("agent encountered errors")
	}
	return nil
}

func (a *App) waitHeadlessReady() error {
	timeout := time.After(60 * time.Second)
	for {
		select {
		case result := <-a.resultCh:
			a.handleResult(result)
			if a.backend == backendCPSL && a.cpslErr != nil {
				fmt.Fprintln(os.Stderr, "error: "+a.cpslErr.Error())
				return a.cpslErr
			}
			if a.backend == backendNaked && a.nakedErr != nil {
				fmt.Fprintln(os.Stderr, "error: "+a.nakedErr.Error())
				return a.nakedErr
			}
			backendReady := true
			switch a.backend {
			case backendCPSL:
				backendReady = a.cpslReady
			case backendNaked:
				backendReady = a.nakedReady
			}
			if a.configReady && a.langdagClient != nil && a.models != nil && backendReady {
				return nil
			}
		case <-timeout:
			if a.backend == backendCPSL && !a.cpslReady {
				if a.cpslErr != nil {
					fmt.Fprintln(os.Stderr, "error: "+a.cpslErr.Error())
					return a.cpslErr
				}
				fmt.Fprintln(os.Stderr, "error: timed out waiting for CPSL worker")
				return fmt.Errorf("CPSL worker initialization timeout")
			}
			if a.backend == backendNaked && !a.nakedReady {
				if a.nakedErr != nil {
					fmt.Fprintln(os.Stderr, "error: "+a.nakedErr.Error())
					return a.nakedErr
				}
				fmt.Fprintln(os.Stderr, "error: timed out waiting for naked sandbox")
				return fmt.Errorf("naked sandbox initialization timeout")
			}
			if a.langdagClient == nil {
				fmt.Fprintln(os.Stderr, "error: timed out waiting for initialization")
				return fmt.Errorf("initialization timeout")
			}
			return nil
		}
	}
}

func (a *App) resolveHeadlessContinuation() error {
	if a.langdagClient == nil {
		fmt.Fprintln(os.Stderr, "error: no API key configured — use herm /config to add one")
		return fmt.Errorf("no API key configured")
	}
	if a.cliContinueID == "" {
		return nil
	}
	node, err := a.langdagClient.GetNode(context.Background(), a.cliContinueID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: resolve --continue %q: %v\n", a.cliContinueID, err)
		a.cleanup()
		return fmt.Errorf("resolve continuation node: %w", err)
	}
	if node == nil {
		fmt.Fprintf(os.Stderr, "error: continuation node not found: %s\n", a.cliContinueID)
		a.cleanup()
		return fmt.Errorf("continuation node not found")
	}
	a.agentNodeID = node.ID
	return nil
}

func (a *App) printHeadlessDebugPath() {
	if a.traceFilePath != "" {
		fmt.Fprintf(os.Stderr, "debug: %s\n", a.traceFilePath)
	}
}

func (a *App) startHeadlessAgent() error {
	a.messages = append(a.messages, chatMessage{kind: msgUser, content: a.cliPrompt, leadBlank: true})
	a.startAgent(a.cliPrompt)
	if a.agentRunning {
		return nil
	}
	for _, msg := range a.messages {
		if msg.kind == msgError {
			fmt.Fprintln(os.Stderr, "error: "+msg.content)
		}
	}
	a.cleanup()
	return fmt.Errorf("agent failed to start")
}

func (a *App) drainHeadlessAgent() {
	for a.agentRunning || a.hasActiveSubAgents() {
		select {
		case event, ok := <-a.agent.Events():
			if !ok {
				a.agentRunning = false
				break
			}
			a.handleAgentEvent(event)
		case result := <-a.resultCh:
			a.handleResult(result)
			a.drainAgentEvents()
		}
	}
}

func (a *App) printHeadlessAssistantOutput() {
	var out strings.Builder
	for _, msg := range a.messages {
		if msg.kind == msgAssistant {
			if out.Len() > 0 {
				out.WriteString("\n")
			}
			out.WriteString(msg.content)
		}
	}
	if out.Len() > 0 {
		fmt.Println(out.String())
	}
}

func (a *App) printHeadlessConversationIDs() {
	if a.agentNodeID == "" {
		return
	}
	node, err := a.langdagClient.GetNode(context.Background(), a.agentNodeID)
	if err != nil || node == nil {
		fmt.Fprintf(os.Stderr, "node_id: %s\n", a.agentNodeID)
		return
	}
	conversationID := node.RootID
	if conversationID == "" {
		conversationID = node.ID
	}
	fmt.Fprintf(os.Stderr, "conversation_id: %s\n", conversationID)
	fmt.Fprintf(os.Stderr, "node_id: %s\n", node.ID)
}

func (a *App) printHeadlessErrors() bool {
	var hasError bool
	for _, msg := range a.messages {
		if msg.kind == msgError {
			fmt.Fprintln(os.Stderr, "error: "+msg.content)
			hasError = true
		}
	}
	return hasError
}
