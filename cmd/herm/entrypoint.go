// entrypoint.go handles process-level CLI flags and starts the interactive
// or headless application mode.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
)

type cliOptions struct {
	debug           bool
	help            bool
	version         bool
	prompt          string
	continueID      string
	configOverrides string
	cacheDir        string
	cpsl            cpslConfig
	naked           bool
}

func main() {
	log.SetOutput(io.Discard)

	if len(os.Args) > 1 && os.Args[1] == "__cpsl-worker" {
		os.Exit(runCPSLWorker(runCPSLWorkerOptions{
			args:   os.Args[2:],
			stdin:  os.Stdin,
			stdout: os.Stdout,
			stderr: os.Stderr,
		}))
	}

	opts, err := parseCLI(parseCLIOptions{args: os.Args[1:], stderr: os.Stderr})
	if err != nil {
		os.Exit(2)
	}
	if opts.help {
		printCLIUsage(os.Stdout)
		return
	}
	if opts.version {
		backend := backendContainer
		if opts.naked {
			backend = backendNaked
		} else if opts.cpsl.LibraryPath != "" {
			backend = backendCPSL
		}
		fmt.Println("herm " + Version + " " + backendVersionSuffix(backend))
		return
	}

	app := newApp()
	app.cliDebug = opts.debug
	app.cliPrompt = opts.prompt
	app.cliContinueID = opts.continueID
	app.cliConfigOverrides = opts.configOverrides
	app.cliCacheDir = opts.cacheDir
	app.cpsl = opts.cpsl
	if opts.naked {
		app.backend = backendNaked
	} else if opts.cpsl.LibraryPath != "" {
		app.backend = backendCPSL
	}
	if _, err := effectiveConfig(effectiveConfigOptions{global: app.globalConfig, project: app.projectConfig, overridesJSON: app.cliConfigOverrides, cacheDir: app.cliCacheDir}); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(2)
	}
	app.rebuildEffectiveConfig()

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

type parseCLIOptions struct {
	args   []string
	stderr io.Writer
}

func parseCLI(opts parseCLIOptions) (cliOptions, error) {
	var parsed cliOptions
	if len(opts.args) == 1 && opts.args[0] == "help" {
		parsed.help = true
		return parsed, nil
	}
	if missingCPSLFlagValue(opts.args) {
		fmt.Fprintln(opts.stderr, cpslLibraryErrorMessage)
		return parsed, errCPSLLibrary
	}
	cpslRequested := hasCPSLFlag(opts.args)
	fs := flag.NewFlagSet("herm", flag.ContinueOnError)
	fs.SetOutput(opts.stderr)
	fs.Usage = func() { printCLIUsage(opts.stderr) }
	var allowDomains stringListFlag
	var denyDomains stringListFlag
	fs.BoolVar(&parsed.help, "help", false, "show help")
	fs.BoolVar(&parsed.help, "h", false, "show help")
	fs.BoolVar(&parsed.version, "version", false, "show version")
	fs.BoolVar(&parsed.version, "v", false, "show version")
	fs.BoolVar(&parsed.debug, "debug", false, "write a JSON debug trace")
	fs.StringVar(&parsed.prompt, "prompt", "", "run one prompt without the TUI")
	fs.StringVar(&parsed.prompt, "p", "", "run one prompt without the TUI")
	fs.StringVar(&parsed.continueID, "continue", "", "continue from a conversation node ID, prefix, or alias")
	fs.StringVar(&parsed.continueID, "from", "", "continue from a conversation node ID, prefix, or alias")
	fs.StringVar(&parsed.configOverrides, "config-overrides", "", "JSON object overlaid onto the effective config")
	fs.StringVar(&parsed.cacheDir, "cache", "", "directory for cached model responses")
	fs.StringVar(&parsed.cpsl.LibraryPath, "cpsl", "", "path to a local sandbox library")
	fs.BoolVar(&parsed.naked, "naked", false, "run directly on the host with workspace-scoped sandboxing")
	fs.Var(&allowDomains, "allow-domain", "allow a domain in sandbox mode")
	fs.Var(&denyDomains, "deny-domain", "deny a domain in sandbox mode")
	if err := fs.Parse(opts.args); err != nil {
		return parsed, err
	}
	if parsed.naked && cpslRequested {
		err := fmt.Errorf("--naked and --cpsl are mutually exclusive")
		fmt.Fprintln(opts.stderr, "Error:", err)
		fs.Usage()
		return parsed, err
	}
	parsed.cpsl.AllowDomains = append([]string(nil), allowDomains...)
	parsed.cpsl.DenyDomains = append([]string(nil), denyDomains...)
	if cpslRequested {
		path, err := validateCPSLLibraryPath(parsed.cpsl.LibraryPath)
		if err != nil {
			fmt.Fprintln(opts.stderr, cpslLibraryErrorMessage)
			return parsed, err
		}
		parsed.cpsl.LibraryPath = path
	}
	if fs.NArg() > 0 {
		if parsed.prompt != "" {
			for _, arg := range fs.Args() {
				if strings.HasPrefix(arg, "-") {
					err := fmt.Errorf("flag-like argument %q appeared after an unquoted prompt; put flags before -p or quote the prompt", arg)
					fmt.Fprintln(opts.stderr, "Error:", err)
					fs.Usage()
					return parsed, err
				}
			}
			parts := append([]string{parsed.prompt}, fs.Args()...)
			parsed.prompt = strings.Join(parts, " ")
			return parsed, nil
		}
		err := fmt.Errorf("unexpected argument: %s", fs.Arg(0))
		fmt.Fprintln(opts.stderr, "Error:", err)
		fs.Usage()
		return parsed, err
	}
	return parsed, nil
}

type stringListFlag []string

func (f *stringListFlag) Set(value string) error {
	*f = append(*f, value)
	return nil
}

func (f *stringListFlag) String() string {
	return strings.Join(*f, ",")
}

func missingCPSLFlagValue(args []string) bool {
	for i, arg := range args {
		if arg != "--cpsl" && arg != "-cpsl" {
			continue
		}
		return i == len(args)-1 || strings.HasPrefix(args[i+1], "-")
	}
	return false
}

func hasCPSLFlag(args []string) bool {
	for _, arg := range args {
		if arg == "--cpsl" || arg == "-cpsl" || strings.HasPrefix(arg, "--cpsl=") || strings.HasPrefix(arg, "-cpsl=") {
			return true
		}
	}
	return false
}

func printCLIUsage(w io.Writer) {
	fmt.Fprintf(w, `Usage:
  herm [flags]
  herm --prompt "prompt" [flags]

Flags:
  -h, --help                       Show this help.
  -v, --version                    Show version information.
      --debug                      Write a JSON debug trace to .herm/debug/.
  -p, --prompt string              Send one prompt without starting the TUI.
      --continue node              Continue from a previous node ID, prefix, or alias.
      --from node                  Alias for --continue.
      --config-overrides json      Overlay config fields for this run only.
      --cache path                 Cache successful model responses in path.
      --cpsl path                  Run with a local sandbox library instead of Docker.
      --naked                      Run on the host with workspace-scoped sandboxing.
      --allow-domain domain        Allow a domain in sandbox mode. Repeatable.
      --deny-domain domain         Deny a domain in sandbox mode. Repeatable.

Examples:
  herm -p say ok
  herm -p 'Hey!'
  herm --continue 4f3a2c1b -p continue this
  herm --cache /tmp/herm-cache -p say ok
  herm --config-overrides '{"active_model":"openai/gpt-4.1-mini-2025-04-14"}' -p say ok

Shell note:
  If a prompt contains ! or nested quotes, prefer single quotes or leave the
  prompt unquoted after -p. Put flags before an unquoted multi-word prompt.
  A dquote> prompt is your shell waiting for a closing quote before Herm starts.
`)
}
