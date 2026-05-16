// entrypoint.go handles process-level CLI flags and starts the interactive
// or headless application mode.
package main

import (
	"fmt"
	"io"
	"log"
	"os"
)

func main() {
	log.SetOutput(io.Discard)

	for _, arg := range os.Args[1:] {
		if arg == "--version" || arg == "-v" {
			fmt.Println("herm " + Version + " (container: " + hermImageTag + ")")
			os.Exit(0)
		}
	}

	app := newApp()

	for i, arg := range os.Args[1:] {
		switch arg {
		case "--debug":
			app.cliDebug = true
		case "--prompt":
			if i+1 < len(os.Args[1:]) {
				app.cliPrompt = os.Args[i+2] // i is 0-based in the slice, +2 to get next arg in os.Args
			}
		}
	}

	if app.cliPrompt != "" {
		app.headless = true
		if err := app.RunHeadless(); err != nil {
			os.Exit(1)
		}
		return
	}

	if err := app.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
