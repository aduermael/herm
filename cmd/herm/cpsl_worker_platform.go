//go:build !darwin

// cpsl_worker_platform.go runs the CPSL worker normally on platforms that do
// not require native evaluation from the process main thread.
package main

func serveCPSLWorkerPlatform(opts serveCPSLWorkerOptions) error {
	return serveCPSLWorker(opts)
}
