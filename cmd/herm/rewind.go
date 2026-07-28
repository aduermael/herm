// rewind.go implements the /rewind command, which lets the user pick a previous
// user message and fork the conversation from before that message.
package main

import (
	"context"
	"fmt"

	"langdag.com/langdag/types"
)

// rewindCheckpoint represents a single user message the user can rewind to.
// parentID is the ID of the node that precedes the user message (empty for
// root messages). Carrying parentID lets us skip a separate GetNode round-trip.
type rewindCheckpoint struct {
	nodeID  string
	parentID string
	label   string
}

// collectRewindCheckpoints extracts user messages from a node chain as rewind
// checkpoints, skipping tool-result user nodes. Each checkpoint carries the
// ParentID of the user message so callers can rewind without an extra lookup.
func collectRewindCheckpoints(nodes []*types.Node) []rewindCheckpoint {
	var checkpoints []rewindCheckpoint
	for _, n := range nodes {
		if n.NodeType == types.NodeTypeUser && !isToolResultContent(n.Content) {
			label := truncate(truncateOptions{s: firstLine(userDisplayContent(n.Content)), max: 60})
			if label == "" {
				label = "(empty message)"
			}
			checkpoints = append(checkpoints, rewindCheckpoint{
				nodeID:   n.ID,
				parentID: n.ParentID,
				label:    label,
			})
		}
	}
	return checkpoints
}

// waitForAgentDone drains agent events until the agent's DoneCh fires or the
// agent is no longer running. This is used to ensure in-flight work is
// completed (or cancelled) before we mutate conversation state.
func (a *App) waitForAgentDone() {
	if a.agent == nil {
		return
	}
	for {
		if !a.agentRunning && !a.hasActiveSubAgents() {
			return
		}
		select {
		case event, ok := <-a.agent.Events():
			if !ok {
				a.agentRunning = false
				a.cancelSent = false
				if a.hasActiveSubAgents() {
					a.forceCompleteSubAgents()
				}
				return
			}
			a.handleAgentEvent(event)
		case <-a.agent.DoneCh():
			for {
				select {
				case event, ok := <-a.agent.Events():
					if !ok {
						a.finalizeAgentTurn("")
						if a.hasActiveSubAgents() {
							a.forceCompleteSubAgents()
						}
						return
					}
					a.handleAgentEvent(event)
				default:
					a.finalizeAgentTurn("")
					if a.hasActiveSubAgents() {
						a.forceCompleteSubAgents()
					}
					return
				}
			}
		}
	}
}

// handleRewindCommand shows user message checkpoints and lets the user
// rewind the conversation to before a selected message. Subsequent messages
// fork the conversation tree from that point.
func (a *App) handleRewindCommand() {
	if a.langdagClient == nil {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "No API client available."})
		a.render()
		return
	}
	if a.agentNodeID == "" {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "No active conversation to rewind."})
		a.render()
		return
	}

	ctx := context.Background()
	ancestors, err := a.langdagClient.GetAncestors(ctx, a.agentNodeID)
	if err != nil {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Rewind error: %v", err)})
		a.render()
		return
	}

	checkpoints := collectRewindCheckpoints(ancestors)
	if len(checkpoints) == 0 {
		a.messages = append(a.messages, chatMessage{kind: msgInfo, content: "No user messages to rewind to."})
		a.render()
		return
	}

	// Show as a menu (newest first so the most recent checkpoint is at the top).
	var lines []string
	for i := len(checkpoints) - 1; i >= 0; i-- {
		lines = append(lines, checkpoints[i].label)
	}
	a.menuLines = lines
	a.menuCursor = 0
	a.menuScrollOffset = 0
	a.menuActive = true
	a.menuHeader = "Rewind to before:"
	a.menuAction = func(idx int) {
		a.menuLines = nil
		a.menuHeader = ""
		a.menuActive = false
		a.menuAction = nil
		a.menuScrollOffset = 0

		if idx < 0 || idx >= len(checkpoints) {
			a.renderInput()
			return
		}
		// Reverse: menu item 0 = most recent checkpoint (last in slice).
		cp := checkpoints[len(checkpoints)-1-idx]

		// Cancel any in-flight agent work and wait for it to finish so late
		// events cannot overwrite the newly rewound state.
		if a.hasCancelableAgentWork() {
			a.requestAgentCancel()
			a.waitForAgentDone()
		}

		// Rewind to the parent of the selected user message so the next
		// user message creates a fork as a sibling of the discarded one.
		// For root messages (empty parentID) we preserve the empty parent
		// to start a fresh conversation.
		targetID := cp.parentID

		a.agentNodeID = targetID
		a.streamingText = ""
		a.pendingToolCall = ""
		a.messages = nil

		// Reuse the ancestors we already fetched: the prefix up to and
		// including the checkpoint's parent is the rewound conversation.
		var rewound []*types.Node
		for _, n := range ancestors {
			if n.ID == cp.nodeID {
				break
			}
			rewound = append(rewound, n)
		}

		a.messages = a.rebuildChatMessages(rewound)
		if len(a.messages) == 0 {
			a.messages = append(a.messages, chatMessage{kind: msgInfo, content: "(start of conversation)"})
		}
		a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Rewound. Next message will fork from here."})
		a.renderFull()
	}
	a.renderInput()
}
