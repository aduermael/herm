// configeditor_animation.go drives lightweight animation for the config editor.
package main

import (
	"time"
)

func (a *App) startConfigTicker() {
	a.stopConfigTicker()
	a.configAnimationStart = time.Now()
	if a.resultCh == nil {
		return
	}
	a.configTicker = time.NewTicker(50 * time.Millisecond)
	stopCh := make(chan struct{})
	a.configTickerStop = stopCh
	go func(ticker *time.Ticker, ch chan any, stopCh <-chan struct{}) {
		for {
			select {
			case <-ticker.C:
				select {
				case ch <- configTickMsg{}:
				default:
				}
			case <-stopCh:
				return
			}
		}
	}(a.configTicker, a.resultCh, stopCh)
}

func (a *App) stopConfigTicker() {
	if a.configTicker != nil {
		a.configTicker.Stop()
		a.configTicker = nil
	}
	if a.configTickerStop != nil {
		close(a.configTickerStop)
		a.configTickerStop = nil
	}
}

func (a *App) configAnimationElapsed() time.Duration {
	if a.configAnimationStart.IsZero() {
		return 0
	}
	return time.Since(a.configAnimationStart)
}
