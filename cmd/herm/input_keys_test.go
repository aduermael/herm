package main

import (
	"testing"
	"time"
)

func newInterruptTestApp() (*App, <-chan struct{}) {
	canceled := make(chan struct{})
	agent := NewAgent(NewAgentOptions{})
	agent.cancelFn = func() {
		select {
		case <-canceled:
		default:
			close(canceled)
		}
	}
	return &App{
		width:        80,
		resultCh:     make(chan any, 4),
		stdinCh:      make(chan byte, 4),
		agent:        agent,
		agentRunning: true,
	}, canceled
}

func TestQuickDoubleEscapeCancelsAgent(t *testing.T) {
	app, canceled := newInterruptTestApp()
	stdinCh := make(chan byte, 1)
	stdinCh <- '\033'

	quit := app.handleByte(handleByteOptions{
		ch:      '\033',
		stdinCh: stdinCh,
		readByte: func() (byte, bool) {
			return 0, false
		},
	})

	if quit {
		t.Fatal("quick double ESC should cancel the agent before force-quitting")
	}
	select {
	case <-canceled:
	default:
		t.Fatal("quick double ESC did not cancel the agent")
	}
	if !app.cancelSent {
		t.Fatal("quick double ESC should mark cancelSent")
	}
}

func TestCtrlCAfterCancelSentForceQuits(t *testing.T) {
	app, _ := newInterruptTestApp()
	app.cancelSent = true

	if !app.handleByte(handleByteOptions{ch: 3}) {
		t.Fatal("Ctrl-C after cancelSent should force quit")
	}
}

func TestEscapeAfterCancelSentForceQuits(t *testing.T) {
	app, _ := newInterruptTestApp()
	app.cancelSent = true

	if !app.handlePlainEscape() {
		t.Fatal("ESC after cancelSent should force quit")
	}
}

func TestSecondCtrlCCancelsAgent(t *testing.T) {
	app, canceled := newInterruptTestApp()
	app.ctrlCHint = true
	app.ctrlCTime = time.Now()

	quit := app.handleByte(handleByteOptions{ch: 3})

	if quit {
		t.Fatal("second Ctrl-C should cancel before force-quitting")
	}
	select {
	case <-canceled:
	default:
		t.Fatal("second Ctrl-C did not cancel the agent")
	}
	if !app.cancelSent {
		t.Fatal("second Ctrl-C should mark cancelSent")
	}
	if !app.ctrlCHint {
		t.Fatal("second Ctrl-C should keep the force-quit hint visible")
	}
}

func TestCtrlCCancelsActiveSubAgentsAfterMainAgentStops(t *testing.T) {
	app, canceled := newInterruptTestApp()
	app.agentRunning = false
	app.subAgents = map[string]*subAgentDisplay{"sub": {done: false}}
	app.ctrlCHint = true
	app.ctrlCTime = time.Now()

	quit := app.handleByte(handleByteOptions{ch: 3})

	if quit {
		t.Fatal("second Ctrl-C should cancel active sub-agents before force-quitting")
	}
	select {
	case <-canceled:
	default:
		t.Fatal("second Ctrl-C did not cancel active sub-agent work")
	}
	if !app.cancelSent {
		t.Fatal("second Ctrl-C should mark cancelSent for active sub-agent work")
	}
}

func TestModifyOtherKeysEscapeCancelsAgent(t *testing.T) {
	app, canceled := newInterruptTestApp()
	app.escHint = true
	app.escTime = time.Now()

	stdinCh := make(chan byte, 1)
	stdinCh <- '['
	seq := []byte("27;1;27~")
	readIdx := 0

	quit := app.handleByte(handleByteOptions{
		ch:      '\033',
		stdinCh: stdinCh,
		readByte: func() (byte, bool) {
			if readIdx >= len(seq) {
				return 0, false
			}
			b := seq[readIdx]
			readIdx++
			return b, true
		},
	})

	if quit {
		t.Fatal("modifyOtherKeys ESC should cancel the agent before force-quitting")
	}
	select {
	case <-canceled:
	default:
		t.Fatal("modifyOtherKeys ESC did not cancel the agent")
	}
}

func newInputKeyTestApp() *App {
	return &App{
		width:    80,
		headless: true,
		resultCh: make(chan any, 4),
		stdinCh:  make(chan byte, 4),
	}
}

func handleCSISequenceForTest(t *testing.T, app *App, seq string) bool {
	t.Helper()
	stdinCh := make(chan byte, 1)
	stdinCh <- '['
	readIdx := 0

	quit := app.handleByte(handleByteOptions{
		ch:      '\033',
		stdinCh: stdinCh,
		readByte: func() (byte, bool) {
			if readIdx >= len(seq) {
				return 0, false
			}
			b := seq[readIdx]
			readIdx++
			return b, true
		},
	})
	if readIdx != len(seq) {
		t.Fatalf("CSI sequence consumed %d bytes, want %d", readIdx, len(seq))
	}
	return quit
}

func TestPlainShiftPrintableInsertsRune(t *testing.T) {
	app := newInputKeyTestApp()

	if app.handleByte(handleByteOptions{ch: 'A'}) {
		t.Fatal("plain Shift+A byte should not quit")
	}
	if got := app.inputValue(); got != "A" {
		t.Fatalf("input after plain Shift+A byte = %q, want %q", got, "A")
	}
}

func TestEncodedShiftPrintableInsertsRune(t *testing.T) {
	tests := []struct {
		name string
		seq  string
		want string
	}{
		{name: "modifyOtherKeys uppercase", seq: "27;2;65~", want: "A"},
		{name: "modifyOtherKeys lowercase with shift", seq: "27;2;97~", want: "A"},
		{name: "CSI u uppercase", seq: "65;2u", want: "A"},
		{name: "CSI u kitty alternate", seq: "97:65;2u", want: "A"},
		{name: "CSI u kitty associated text", seq: "97;2;65u", want: "A"},
		{name: "CSI u shifted punctuation", seq: "49;2;33u", want: "!"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			app := newInputKeyTestApp()

			if handleCSISequenceForTest(t, app, tt.seq) {
				t.Fatalf("%s sequence should not quit", tt.name)
			}
			if got := app.inputValue(); got != tt.want {
				t.Fatalf("input after %s = %q, want %q", tt.name, got, tt.want)
			}
		})
	}
}

func TestEncodedShiftEnterInsertsNewline(t *testing.T) {
	tests := []struct {
		name string
		seq  string
	}{
		{name: "modifyOtherKeys CR", seq: "27;2;13~"},
		{name: "CSI u CR", seq: "13;2u"},
		{name: "CSI u LF", seq: "10;2u"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			app := newInputKeyTestApp()
			app.input = []rune("a")
			app.cursor = len(app.input)

			if handleCSISequenceForTest(t, app, tt.seq) {
				t.Fatalf("%s sequence should not quit", tt.name)
			}
			if got := app.inputValue(); got != "a\n" {
				t.Fatalf("input after %s = %q, want %q", tt.name, got, "a\n")
			}
		})
	}
}

func TestEncodedShiftEnterBlockedByMenu(t *testing.T) {
	app := newInputKeyTestApp()
	app.menuActive = true

	if handleCSISequenceForTest(t, app, "13;2u") {
		t.Fatal("Shift+Enter CSI u sequence should not quit")
	}
	if got := app.inputValue(); got != "" {
		t.Fatalf("menu should block encoded Shift+Enter, got input %q", got)
	}
}

func TestEncodedCtrlShiftLetterUsesCtrlShortcut(t *testing.T) {
	app := newInputKeyTestApp()
	app.input = []rune("abc")
	app.cursor = len(app.input)

	if handleCSISequenceForTest(t, app, "27;6;65~") {
		t.Fatal("Ctrl+Shift+A modifyOtherKeys sequence should not quit")
	}
	ch := <-app.stdinCh
	if ch != 0x01 {
		t.Fatalf("Ctrl+Shift+A injected byte = %#x, want Ctrl+A", ch)
	}
	if got := app.inputValue(); got != "abc" {
		t.Fatalf("Ctrl+Shift+A should not insert text, got input %q", got)
	}
}

func TestEncodedShiftPrintableInConfigEditInsertsRune(t *testing.T) {
	tests := []struct {
		name string
		seq  string
	}{
		{name: "modifyOtherKeys", seq: "27;2;65~"},
		{name: "CSI u", seq: "65;2u"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			app := newInputKeyTestApp()
			app.cfgActive = true
			app.cfgEditing = true
			app.cfgEditBuf = []rune("x")
			app.cfgEditCursor = len(app.cfgEditBuf)

			if handleCSISequenceForTest(t, app, tt.seq) {
				t.Fatalf("%s sequence should not quit", tt.name)
			}
			if got := string(app.cfgEditBuf); got != "xA" {
				t.Fatalf("config edit input after %s = %q, want %q", tt.name, got, "xA")
			}
			if got := app.inputValue(); got != "" {
				t.Fatalf("config edit should not insert into chat input, got %q", got)
			}
		})
	}
}

func TestEncodedShiftPrintableInConfigModeIsConsumed(t *testing.T) {
	app := newInputKeyTestApp()
	app.cfgActive = true

	if handleCSISequenceForTest(t, app, "65;2u") {
		t.Fatal("Shift+A CSI u config sequence should not quit")
	}
	if got := app.inputValue(); got != "" {
		t.Fatalf("config mode should ignore printable key outside edit mode, got chat input %q", got)
	}
}

func TestBracketedPasteInConfigModeIsConsumed(t *testing.T) {
	app := newInputKeyTestApp()
	app.cfgActive = true

	if handleCSISequenceForTest(t, app, "200~ignored\033[201~") {
		t.Fatal("bracketed paste in config mode should not quit")
	}
	if got := app.inputValue(); got != "" {
		t.Fatalf("config mode should ignore pasted text outside edit mode, got chat input %q", got)
	}
}

func TestOldEscapeExpiryDoesNotClearNewHint(t *testing.T) {
	app, _ := newInterruptTestApp()
	app.escHint = true
	app.escTime = time.Now()

	app.handleResult(escExpiredMsg{})
	if !app.escHint {
		t.Fatal("old ESC expiry should not clear a newer hint")
	}

	app.escTime = time.Now().Add(-interruptTapWindow - time.Millisecond)
	app.handleResult(escExpiredMsg{})
	if app.escHint {
		t.Fatal("expired ESC hint should be cleared")
	}
}

func TestDoubleEscapeDuringApprovalCancelsAgent(t *testing.T) {
	app, canceled := newInterruptTestApp()
	app.awaitingApproval = true

	if app.handlePlainEscape() {
		t.Fatal("first ESC during approval should deny and arm cancel, not quit")
	}
	if app.awaitingApproval {
		t.Fatal("first ESC should deny pending approval")
	}
	if !app.escHint {
		t.Fatal("first ESC during approval should arm the interrupt hint")
	}

	if app.handlePlainEscape() {
		t.Fatal("second ESC during approval flow should cancel before force-quitting")
	}
	select {
	case <-canceled:
	default:
		t.Fatal("second ESC during approval flow did not cancel the agent")
	}
}

func TestApprovalSelectionEnterSendsRememberedApproval(t *testing.T) {
	app, _ := newInterruptTestApp()
	app.awaitingApproval = true
	app.approvalPauseStart = time.Now()

	app.handleApprovalNavKey('C')
	if app.approvalSelected != 1 {
		t.Fatalf("approvalSelected = %d, want always-accept option", app.approvalSelected)
	}
	app.handleApprovalByte('\r')

	select {
	case resp := <-app.agent.approval:
		if !resp.Approved || !resp.Remember {
			t.Fatalf("approval response = %#v, want approved remembered", resp)
		}
	default:
		t.Fatal("approval response not sent")
	}
}

func TestApprovalPlainYAcceptsOnce(t *testing.T) {
	app, _ := newInterruptTestApp()
	app.awaitingApproval = true
	app.approvalPauseStart = time.Now()

	app.handleApprovalByte('y')

	select {
	case resp := <-app.agent.approval:
		if !resp.Approved || resp.Remember {
			t.Fatalf("approval response = %#v, want approved once", resp)
		}
	default:
		t.Fatal("approval response not sent")
	}
}

func TestApprovalEncodedCmdYAlwaysAccepts(t *testing.T) {
	app, _ := newInterruptTestApp()
	app.awaitingApproval = true
	app.approvalPauseStart = time.Now()

	app.handleApprovalEncodedKey(handleApprovalEncodedKeyOptions{mod: 9, code: 'y'})

	select {
	case resp := <-app.agent.approval:
		if !resp.Approved || !resp.Remember {
			t.Fatalf("approval response = %#v, want approved remembered", resp)
		}
	default:
		t.Fatal("approval response not sent")
	}
}
