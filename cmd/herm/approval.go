// approval.go contains the interactive tool-approval state transitions.
package main

import (
	"time"
)

type approvalDecision int

const (
	approvalAcceptOnce approvalDecision = iota
	approvalAcceptAlways
	approvalDeny
)

func (a *App) handleApprovalByte(ch byte) {
	switch ch {
	case 'y', 'Y':
		a.applyApprovalDecision(approvalAcceptOnce)
	case 'n', 'N':
		a.applyApprovalDecision(approvalDeny)
	case '\r', '\n':
		switch a.approvalSelected {
		case 1:
			a.applyApprovalDecision(approvalAcceptAlways)
		case 2:
			a.applyApprovalDecision(approvalDeny)
		default:
			a.applyApprovalDecision(approvalAcceptOnce)
		}
	}
}

func (a *App) applyApprovalDecision(decision approvalDecision) {
	a.awaitingApproval = false
	var waitDur time.Duration
	if !a.approvalPauseStart.IsZero() {
		waitDur = time.Since(a.approvalPauseStart)
		a.approvalPausedTotal += waitDur
		a.approvalPauseStart = time.Time{}
	}
	approved := decision != approvalDeny
	if a.traceCollector != nil && a.approvalToolID != "" {
		a.traceCollector.AddApproval(AddApprovalOptions{toolID: a.approvalToolID, desc: a.approvalDesc, approved: approved, waitDur: waitDur})
	}
	if approved {
		a.restartApprovalToolTimer()
	}
	if a.agent != nil {
		a.agent.Approve(ApprovalResponse{Approved: approved, Remember: decision == approvalAcceptAlways})
	}
	switch decision {
	case approvalAcceptAlways:
		a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Always approved"})
	case approvalDeny:
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "Denied"})
	default:
		a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Approved once"})
	}
	a.approvalSelected = 0
	a.render()
}

func (a *App) restartApprovalToolTimer() {
	if a.toolStartTime.IsZero() || a.toolTimer != nil {
		return
	}
	a.toolTimer = time.NewTicker(100 * time.Millisecond)
	go func(ticker *time.Ticker, ch chan any) {
		for range ticker.C {
			select {
			case ch <- toolTimerTickMsg{}:
			default:
			}
		}
	}(a.toolTimer, a.resultCh)
}
