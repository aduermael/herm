//go:build darwin

// cpsl_worker_platform_darwin.go routes CPSL worker evaluations through the
// locked process main thread required by Darwin native libraries.
package main

import (
	"fmt"
	"os"
	"runtime"
)

func init() {
	if len(os.Args) > 1 && os.Args[1] == "__cpsl-worker" {
		runtime.LockOSThread()
	}
}

type cpslMainThreadEvaluator struct {
	base   cpslSessionEvaluator
	jobs   chan cpslMainThreadEvalJob
	closed chan struct{}
}

type cpslMainThreadEvalJob struct {
	session     cpslSession
	requestJSON string
	response    chan cpslMainThreadEvalResult
}

type cpslMainThreadEvalResult struct {
	responseJSON string
	err          error
}

func serveCPSLWorkerPlatform(opts serveCPSLWorkerOptions) error {
	evaluator := &cpslMainThreadEvaluator{
		base:   opts.evaluator,
		jobs:   make(chan cpslMainThreadEvalJob),
		closed: make(chan struct{}),
	}
	opts.evaluator = evaluator

	done := make(chan error, 1)
	go func() {
		done <- serveCPSLWorker(opts)
	}()

	return evaluator.run(done)
}

func (e *cpslMainThreadEvaluator) eval(opts cpslSessionEvalOptions) (string, error) {
	response := make(chan cpslMainThreadEvalResult, 1)
	job := cpslMainThreadEvalJob{
		session:     opts.session,
		requestJSON: opts.requestJSON,
		response:    response,
	}

	select {
	case e.jobs <- job:
	case <-e.closed:
		return "", fmt.Errorf("CPSL main-thread evaluator stopped")
	}

	select {
	case result := <-response:
		return result.responseJSON, result.err
	case <-e.closed:
		return "", fmt.Errorf("CPSL main-thread evaluator stopped")
	}
}

func (e *cpslMainThreadEvaluator) run(done <-chan error) error {
	defer close(e.closed)
	for {
		select {
		case job := <-e.jobs:
			responseJSON, err := e.base.eval(cpslSessionEvalOptions{session: job.session, requestJSON: job.requestJSON})
			job.response <- cpslMainThreadEvalResult{responseJSON: responseJSON, err: err}
		case err := <-done:
			return err
		}
	}
}
