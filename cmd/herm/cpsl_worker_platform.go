//go:build !darwin

package main

func serveCPSLWorkerPlatform(opts serveCPSLWorkerOptions) error {
	return serveCPSLWorker(opts)
}
