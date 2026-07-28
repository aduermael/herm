package main

import (
	"encoding/json"
	"strings"
	"testing"

	"langdag.com/langdag/types"
)

// ─── rewind checkpoints ───

func TestCollectRewindCheckpoints_Empty(t *testing.T) {
	got := collectRewindCheckpoints(nil)
	if len(got) != 0 {
		t.Errorf("nil input: got %d checkpoints, want 0", len(got))
	}

	got = collectRewindCheckpoints([]*types.Node{})
	if len(got) != 0 {
		t.Errorf("empty input: got %d checkpoints, want 0", len(got))
	}
}

func TestCollectRewindCheckpoints_OnlyUserMessages(t *testing.T) {
	nodes := []*types.Node{
		{ID: "1", NodeType: types.NodeTypeUser, Content: "Hello"},
		{ID: "2", NodeType: types.NodeTypeUser, Content: "How are you?"},
		{ID: "3", NodeType: types.NodeTypeUser, Content: "Fix this bug"},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 3 {
		t.Fatalf("got %d checkpoints, want 3", len(got))
	}
	if got[0].label != "Hello" {
		t.Errorf("checkpoint[0].label = %q, want %q", got[0].label, "Hello")
	}
	if got[1].label != "How are you?" {
		t.Errorf("checkpoint[1].label = %q, want %q", got[1].label, "How are you?")
	}
	if got[2].label != "Fix this bug" {
		t.Errorf("checkpoint[2].label = %q, want %q", got[2].label, "Fix this bug")
	}
	if got[0].nodeID != "1" || got[1].nodeID != "2" || got[2].nodeID != "3" {
		t.Errorf("nodeID mismatch: got %v, %v, %v", got[0].nodeID, got[1].nodeID, got[2].nodeID)
	}
}

func TestCollectRewindCheckpoints_CarriesParentID(t *testing.T) {
	nodes := []*types.Node{
		{ID: "root", NodeType: types.NodeTypeUser, Content: "Start", ParentID: ""},
		{ID: "a1", NodeType: types.NodeTypeAssistant, Content: "Hi"},
		{ID: "u1", NodeType: types.NodeTypeUser, Content: "Next", ParentID: "a1"},
		{ID: "a2", NodeType: types.NodeTypeAssistant, Content: "OK"},
		{ID: "u2", NodeType: types.NodeTypeUser, Content: "Again", ParentID: "a2"},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 3 {
		t.Fatalf("got %d checkpoints, want 3", len(got))
	}
	if got[0].parentID != "" {
		t.Errorf("root checkpoint parentID = %q, want empty", got[0].parentID)
	}
	if got[1].parentID != "a1" {
		t.Errorf("middle checkpoint parentID = %q, want %q", got[1].parentID, "a1")
	}
	if got[2].parentID != "a2" {
		t.Errorf("last checkpoint parentID = %q, want %q", got[2].parentID, "a2")
	}
}

func TestCollectRewindCheckpoints_SkipsToolResults(t *testing.T) {
	nodes := []*types.Node{
		{ID: "1", NodeType: types.NodeTypeUser, Content: "Run ls"},
		{ID: "2", NodeType: types.NodeTypeUser, Content: `[{"type":"tool_result","tool_use_id":"call_1","content":"file1.go"}]`},
		{ID: "3", NodeType: types.NodeTypeUser, Content: "Check git status"},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 2 {
		t.Fatalf("got %d checkpoints, want 2 (tool result should be skipped)", len(got))
	}
	if got[0].label != "Run ls" {
		t.Errorf("checkpoint[0].label = %q, want %q", got[0].label, "Run ls")
	}
	if got[1].label != "Check git status" {
		t.Errorf("checkpoint[1].label = %q, want %q", got[1].label, "Check git status")
	}
}

func TestCollectRewindCheckpoints_SkipsNonUserNodes(t *testing.T) {
	nodes := []*types.Node{
		{ID: "1", NodeType: types.NodeTypeUser, Content: "Hello"},
		{ID: "2", NodeType: types.NodeTypeAssistant, Content: "Hi there!"},
		{ID: "3", NodeType: types.NodeTypeUser, Content: "Help me"},
		{ID: "4", NodeType: types.NodeTypeToolCall, Content: `{"name":"bash","input":{}}`},
		{ID: "5", NodeType: types.NodeTypeToolResult, Content: "done"},
		{ID: "6", NodeType: types.NodeTypeUser, Content: "Thanks"},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 3 {
		t.Fatalf("got %d checkpoints, want 3 (only user messages)", len(got))
	}
	if got[0].label != "Hello" {
		t.Errorf("checkpoint[0].label = %q", got[0].label)
	}
	if got[1].label != "Help me" {
		t.Errorf("checkpoint[1].label = %q", got[1].label)
	}
	if got[2].label != "Thanks" {
		t.Errorf("checkpoint[2].label = %q", got[2].label)
	}
}

func TestCollectRewindCheckpoints_TruncatesLongLabels(t *testing.T) {
	long := "This is a very long message that should definitely be truncated because it exceeds the maximum label length of sixty characters"
	nodes := []*types.Node{
		{ID: "1", NodeType: types.NodeTypeUser, Content: long},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 1 {
		t.Fatalf("got %d checkpoints, want 1", len(got))
	}
	const maxBytes = 60
	if len(got[0].label) > maxBytes+2 {
		t.Errorf("label byte length = %d, want <= %d", len(got[0].label), maxBytes+2)
	}
	if !strings.HasSuffix(got[0].label, "…") {
		t.Errorf("truncated label should end with …, got %q", got[0].label)
	}
}

func TestCollectRewindCheckpoints_EmptyContent(t *testing.T) {
	nodes := []*types.Node{
		{ID: "1", NodeType: types.NodeTypeUser, Content: ""},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 1 {
		t.Fatalf("got %d checkpoints, want 1", len(got))
	}
	if got[0].label != "(empty message)" {
		t.Errorf("empty content label = %q, want %q", got[0].label, "(empty message)")
	}
}

func TestCollectRewindCheckpoints_OnlyFirstLine(t *testing.T) {
	nodes := []*types.Node{
		{ID: "1", NodeType: types.NodeTypeUser, Content: "First line\nSecond line\nThird line"},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 1 {
		t.Fatalf("got %d checkpoints, want 1", len(got))
	}
	if got[0].label != "First line" {
		t.Errorf("label should be first line only, got %q", got[0].label)
	}
}

func TestCollectRewindCheckpoints_MixedConversation(t *testing.T) {
	nodes := []*types.Node{
		{ID: "u1", NodeType: types.NodeTypeUser, Content: "Build a REST API"},
		{ID: "a1", NodeType: types.NodeTypeAssistant, Content: "Sure, let me plan."},
		{ID: "tr1", NodeType: types.NodeTypeUser,
			Content: `[{"type":"tool_result","tool_use_id":"call_1","content":"ok"}]`},
		{ID: "a2", NodeType: types.NodeTypeAssistant, Content: "Done with planning."},
		{ID: "u2", NodeType: types.NodeTypeUser, Content: "Add auth"},
		{ID: "tr2", NodeType: types.NodeTypeUser,
			Content: `[{"type":"tool_result","tool_use_id":"call_2","content":"done"}]`},
		{ID: "a3", NodeType: types.NodeTypeAssistant, Content: "Auth added."},
		{ID: "u3", NodeType: types.NodeTypeUser, Content: "Add tests"},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 3 {
		t.Fatalf("got %d checkpoints, want 3 (u1, u2, u3)", len(got))
	}
	if got[0].nodeID != "u1" || got[0].label != "Build a REST API" {
		t.Errorf("checkpoint[0] = %+v", got[0])
	}
	if got[1].nodeID != "u2" || got[1].label != "Add auth" {
		t.Errorf("checkpoint[1] = %+v", got[1])
	}
	if got[2].nodeID != "u3" || got[2].label != "Add tests" {
		t.Errorf("checkpoint[2] = %+v", got[2])
	}
}

func TestCollectRewindCheckpoints_SystemReminderStripped(t *testing.T) {
	content := "<system-reminder>\nKeep context\n</system-reminder>\n\nActual question"
	nodes := []*types.Node{
		{ID: "1", NodeType: types.NodeTypeUser, Content: content},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 1 {
		t.Fatalf("got %d checkpoints, want 1", len(got))
	}
	if got[0].label != "Actual question" {
		t.Errorf("label should have system-reminder stripped, got %q", got[0].label)
	}
}

func TestCollectRewindCheckpoints_SystemReminderOnly(t *testing.T) {
	blocks, _ := json.Marshal([]types.ContentBlock{
		{Type: "text", Text: "<system-reminder>\nKeep context\n</system-reminder>"},
	})
	nodes := []*types.Node{
		{ID: "1", NodeType: types.NodeTypeUser, Content: string(blocks)},
	}
	got := collectRewindCheckpoints(nodes)
	if len(got) != 1 {
		t.Fatalf("got %d checkpoints, want 1", len(got))
	}
	if got[0].label != "(empty message)" {
		t.Errorf("system-reminder-only message should show '(empty message)', got %q", got[0].label)
	}
}

// ─── rewind target selection ───

func TestRewindTarget_RootCheckpointPreservesEmptyParent(t *testing.T) {
	checkpoints := []rewindCheckpoint{
		{nodeID: "root", parentID: "", label: "Start"},
	}
	cp := checkpoints[0]
	targetID := cp.parentID
	if targetID != "" {
		t.Errorf("root checkpoint targetID = %q, want empty (fresh conversation)", targetID)
	}
}

func TestRewindTarget_MiddleCheckpointUsesParentID(t *testing.T) {
	checkpoints := []rewindCheckpoint{
		{nodeID: "u1", parentID: "", label: "Start"},
		{nodeID: "u2", parentID: "a1", label: "Next"},
		{nodeID: "u3", parentID: "a2", label: "Again"},
	}
	cp := checkpoints[1]
	targetID := cp.parentID
	if targetID != "a1" {
		t.Errorf("middle checkpoint targetID = %q, want %q", targetID, "a1")
	}
}

// ─── rewind ancestor prefix reuse ───

func TestRewindPrefix_RootCheckpointYieldsEmptyPrefix(t *testing.T) {
	ancestors := []*types.Node{
		{ID: "root", NodeType: types.NodeTypeUser, Content: "Start", ParentID: ""},
		{ID: "a1", NodeType: types.NodeTypeAssistant, Content: "Hi"},
		{ID: "u1", NodeType: types.NodeTypeUser, Content: "Next", ParentID: "a1"},
	}
	cp := rewindCheckpoint{nodeID: "root", parentID: ""}
	var rewound []*types.Node
	for _, n := range ancestors {
		if n.ID == cp.nodeID {
			break
		}
		rewound = append(rewound, n)
	}
	if len(rewound) != 0 {
		t.Errorf("root checkpoint rewound prefix = %d nodes, want 0 (fresh conversation)", len(rewound))
	}
}

func TestRewindPrefix_MiddleCheckpointYieldsCorrectPrefix(t *testing.T) {
	ancestors := []*types.Node{
		{ID: "root", NodeType: types.NodeTypeUser, Content: "Start", ParentID: ""},
		{ID: "a1", NodeType: types.NodeTypeAssistant, Content: "Hi"},
		{ID: "u1", NodeType: types.NodeTypeUser, Content: "Next", ParentID: "a1"},
		{ID: "a2", NodeType: types.NodeTypeAssistant, Content: "OK"},
		{ID: "u2", NodeType: types.NodeTypeUser, Content: "Again", ParentID: "a2"},
	}
	cp := rewindCheckpoint{nodeID: "u1", parentID: "a1"}
	var rewound []*types.Node
	for _, n := range ancestors {
		if n.ID == cp.nodeID {
			break
		}
		rewound = append(rewound, n)
	}
	if len(rewound) != 2 {
		t.Fatalf("middle checkpoint rewound prefix = %d nodes, want 2", len(rewound))
	}
	if rewound[0].ID != "root" {
		t.Errorf("rewound[0].ID = %q, want %q", rewound[0].ID, "root")
	}
	if rewound[1].ID != "a1" {
		t.Errorf("rewound[1].ID = %q, want %q", rewound[1].ID, "a1")
	}
}

func TestRewindPrefix_LastCheckpointYieldsFullPrefixExceptSelf(t *testing.T) {
	ancestors := []*types.Node{
		{ID: "root", NodeType: types.NodeTypeUser, Content: "Start", ParentID: ""},
		{ID: "a1", NodeType: types.NodeTypeAssistant, Content: "Hi"},
		{ID: "u1", NodeType: types.NodeTypeUser, Content: "Next", ParentID: "a1"},
		{ID: "a2", NodeType: types.NodeTypeAssistant, Content: "OK"},
		{ID: "u2", NodeType: types.NodeTypeUser, Content: "Again", ParentID: "a2"},
	}
	cp := rewindCheckpoint{nodeID: "u2", parentID: "a2"}
	var rewound []*types.Node
	for _, n := range ancestors {
		if n.ID == cp.nodeID {
			break
		}
		rewound = append(rewound, n)
	}
	if len(rewound) != 4 {
		t.Fatalf("last checkpoint rewound prefix = %d nodes, want 4", len(rewound))
	}
	if rewound[3].ID != "a2" {
		t.Errorf("rewound[3].ID = %q, want %q", rewound[3].ID, "a2")
	}
}
