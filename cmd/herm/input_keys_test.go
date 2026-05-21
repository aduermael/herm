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
