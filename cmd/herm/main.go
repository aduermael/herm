// main.go implements the herm terminal UI, rendering, input handling, and
// program entry point.
package main

import (
	"crypto/rand"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"
	"langdag.com/langdag"
)

var Version = "dev"

const (
	promptPrefix       = "▸ "
	promptPrefixCols   = 2
	charsPerToken      = 4        // rough estimate for context bar
	maxAttachmentBytes = 20 << 20 // 20 MB
)

type chatMsgKind int

const (
	msgUser chatMsgKind = iota
	msgAssistant
	msgToolCall
	msgToolResult
	msgInfo
	msgSystemPrompt
	msgSuccess
	msgError
	msgSubAgentGroup // positional anchor for the sub-agent display block
)

type chatMessage struct {
	kind            chatMsgKind
	content         string
	inlineBlocks    []inlineBlock // optional atomic one-line UI blocks for terminal layout
	modelDiagnostic bool          // true for active/exploration model fallback warnings
	modelDisplay    bool          // true for the "Using active/exploration" status line
	isError         bool          // for tool results
	duration        time.Duration // tool execution duration
	leadBlank       bool          // blank line before this message
	toolName        string        // original tool name (for tool call grouping/output rules)
}

type appMode int

const (
	modeChat appMode = iota
	modeConfig
	modeModel
	modeWorktrees
	modeBranches
)

type App struct {
	// Terminal
	fd       int
	oldState *term.State
	width    int

	// Rendering state (from simple-chat)
	prevRowCount  int
	sepRow        int
	inputStartRow int
	scrollShift   int // rows scrolled off top when content > terminal height

	// Input buffer (from simple-chat)
	input   []rune
	cursor  int
	history *History

	// Event channels
	resultCh chan any
	stopCh   chan struct{}
	quit     bool

	// Stdin goroutine control
	stdinDup *os.File  // dup'd stdin fd for the reader goroutine
	stdinCh  chan byte // channel carrying bytes from the reader goroutine
	readByte func() (byte, bool)

	// Chat state
	sessionID               string
	messages                []chatMessage
	globalConfig            Config        // loaded from ~/.herm/config.json
	projectConfig           ProjectConfig // loaded from <repo>/.herm/config.json
	config                  Config        // merged effective config (globalConfig + projectConfig)
	repoRoot                string        // git repo root, for project config path
	pasteCount              int
	pasteStore              map[int]string
	attachmentCount         int
	attachments             map[int]Attachment
	mode                    appMode
	models                  []ModelDef
	sweScores               map[string]float64
	sweLoaded               bool
	container               *ContainerClient
	worktreePath            string
	containerReady          bool
	containerErr            error
	containerStatusText     string
	cpslWorker              cpslWorkerBackend
	cpslReady               bool
	cpslErr                 error
	cpslStatusText          string
	containerRetryMsgIdx    int
	containerRetryMsgActive bool
	configReady             bool // true after workspace/project config has been merged
	shownInitialModel       bool // true after the startup model line has been displayed
	lastModelDiagnostics    string
	ollamaFetched           bool // true after the initial Ollama model fetch completes (or was skipped)
	openRouterFetched       bool // true after initial OpenRouter fetch
	appleFetched            bool // true after initial Apple Foundation Models health fetch
	status                  statusInfo
	projectSnap             *projectSnapshot
	modelCatalog            *langdag.ModelCatalog
	langdagClient           *langdag.Client
	langdagProvider         string
	langdagRuntimeApple     bool
	agent                   *Agent
	agentNodeID             string
	agentRunning            bool
	awaitingApproval        bool
	approvalDesc            string
	approvalSummary         string
	autocompleteIdx         int
	streamingText           string
	pendingToolCall         string
	needsTextSep            bool
	sessionCostUSD          float64
	lastInputTokens         int                         // input tokens from most recent API call (context usage)
	sessionInputTokens      int                         // cumulative input tokens this session (all agents)
	sessionOutputTokens     int                         // cumulative output tokens this session (all agents)
	sessionCacheRead        int                         // cumulative cache read tokens this session
	sessionLLMCalls         int                         // number of LLM API calls this session (all agents)
	mainAgentInputTokens    int                         // input tokens from main agent only
	mainAgentOutputTokens   int                         // output tokens from main agent only
	mainAgentLLMCalls       int                         // LLM calls from main agent only
	mainAgentToolCount      int                         // tool results from main agent only
	sessionToolResults      int                         // count of tool results this session
	sessionToolBytes        int                         // cumulative tool result bytes this session
	sessionToolStats        map[string][2]int           // tool name → [count, bytes]
	lastModelID             string                      // last model used, for detecting changes
	lastModelDisplayLine    string                      // last full model display line, including exploration model
	lastOllamaOfflineNotice string                      // last Ollama offline warning line, for dedupe
	subAgents               map[string]*subAgentDisplay // per-agent display state keyed by AgentID
	subAgentGroupInserted   bool                        // true after a msgSubAgentGroup marker has been added to messages
	suppressedToolIDs       map[string]bool             // tool IDs whose UI messages should be hidden
	containerImage          string                      // runtime container image name (not persisted)
	updateAvailable         string                      // version tag if update is available

	// Tool timer (live elapsed display)
	toolStartTime time.Time
	toolTimer     *time.Ticker

	// Agent status timer (animated label while agent is running)
	agentStartTime     time.Time
	agentTicker        *time.Ticker
	agentElapsed       time.Duration // persists final time after agent stops
	agentTextIndex     int           // which funny text is showing
	agentDisplayInTok  float64       // lerped display value for input tokens
	agentDisplayOutTok float64       // lerped display value for output tokens

	// Config editor animation timer
	configAnimationStart time.Time
	configTicker         *time.Ticker
	configTickerStop     chan struct{}

	// Approval timer pause
	approvalPauseStart  time.Time     // when approval wait started
	approvalPausedTotal time.Duration // total time spent waiting for approvals
	approvalToolID      string        // tool ID of pending approval (for trace)

	// Periodic commit info refresh
	commitInfoTicker *time.Ticker

	// Menu state(for inline menus below input)
	menuLines        []string
	menuHeader       string // optional header row above scrollable items
	menuCursor       int
	menuActive       bool
	menuAction       func(int)
	menuScrollOffset int
	menuSortCol      int        // active sort column (0=name,1=provider,2=price,3=context)
	menuSortAsc      [4]bool    // per-column sort direction: true=ascending
	menuModels       []ModelDef // model list for re-sorting (nil for non-model menus)
	menuActiveID     string     // active model ID for re-sorting

	// Config editor state
	cfgActive        bool
	cfgTab           int
	cfgCursor        int
	cfgTabCursor     [cfgTabCount]int // remembered cursor per config tab
	cfgEditing       bool
	cfgEditBuf       []rune
	cfgEditCursor    int
	cfgChangedLabels map[string]string // tracks field labels and their change direction ("saved", "removed", "updated")
	cfgDraft         Config
	cfgProjectDraft  ProjectConfig
	configJSONEditor func(string) error // injectable for tests; nil uses $VISUAL/$EDITOR

	// Text prompt overlay (e.g. "Enter worktree name:")
	promptLabel    string
	promptCallback func(string) // called with entered text; nil when inactive

	// Ctrl+C double-tap to exit
	ctrlCTime time.Time // when last Ctrl+C was pressed (for double-tap detection)
	ctrlCHint bool      // show "Press Ctrl-C again to exit" hint

	// ESC double-tap to stop agent
	escTime time.Time
	escHint bool

	// Force-quit: tracks whether Cancel() was already issued so a subsequent
	// Ctrl-C or ESC forces an immediate exit.
	cancelSent bool

	// CLI flags
	cliDebug           bool   // --debug flag
	cliPrompt          string // --prompt/-p flag (non-interactive mode)
	cliContinueID      string // --continue/--from node ID for headless continuation
	cliConfigOverrides string // --config-overrides JSON object
	cliCacheDir        string // --cache directory for request cache
	backend            backendKind
	cpsl               cpslConfig
	headless           bool // true when running in --prompt mode (no TUI)

	// JSON trace debug file
	traceCollector *TraceCollector
	traceFilePath  string
	traceUsageSeen bool // true after EventUsage, reset on turn boundary or EventDone
}

func newApp() *App {
	cfg, err := loadConfig()
	if err != nil {
		log.Printf("warning: loading config: %v (using defaults)", err)
	}

	var sid [4]byte
	_, _ = rand.Read(sid[:])
	sessID := fmt.Sprintf("%08x", sid)

	return &App{
		sessionID:    sessID,
		globalConfig: cfg,
		config:       cfg, // no project config yet; will merge on workspaceMsg
		resultCh:     make(chan any, 16),
		stopCh:       make(chan struct{}),
	}
}

// ─── Rendering (from simple-chat, adapted) ───

// agentElapsedTime returns elapsed agent time, excluding approval wait time.
func (a *App) agentElapsedTime() time.Duration {
	elapsed := time.Since(a.agentStartTime)
	elapsed -= a.approvalPausedTotal
	if a.awaitingApproval && !a.approvalPauseStart.IsZero() {
		elapsed -= time.Since(a.approvalPauseStart)
	}
	if elapsed < 0 {
		elapsed = 0
	}
	return elapsed
}

// ─── Main event loop ───

func (a *App) Run() error {
	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return fmt.Errorf("entering raw mode: %w", err)
	}
	a.fd = fd
	a.oldState = oldState

	startTime := time.Now()

	// Panic-safe terminal restoration
	defer func() {
		if r := recover(); r != nil {
			term.Restore(fd, oldState)
			panic(r)
		}
	}()

	saveTerminalTitle(os.Stdout)
	setHermTerminalTitle(os.Stdout)
	defer restoreTerminalTitle(os.Stdout)

	// Enable bracketed paste and modifyOtherKeys (no alt screen — use main buffer
	// so native terminal scrollback works)
	fmt.Print("\033[?2004h")
	fmt.Print("\033[>4;2m")
	defer func() {
		fmt.Print("\033[?25h")  // ensure cursor visible on exit
		fmt.Print("\033[>4;0m") // disable modifyOtherKeys
		fmt.Print("\033[?2004l")
		// Position cursor below rendered content so shell prompt appears cleanly
		th := getTerminalHeight()
		lastVisRow := a.prevRowCount
		if lastVisRow > th {
			lastVisRow = th
		}
		if lastVisRow > 0 {
			fmt.Printf("\033[%d;1H", lastVisRow)
		}
		fmt.Print("\r\n")
		end := time.Now()
		fmt.Printf("[HERM %s -> %s]\r\n",
			startTime.Format("Jan 02 15:04"),
			end.Format("Jan 02 15:04"))
		term.Restore(fd, oldState)
	}()

	a.width = getWidth()

	// SIGWINCH handler with debounce
	sigWinch := make(chan os.Signal, 1)
	signal.Notify(sigWinch, syscall.SIGWINCH)
	resizeDb := newDebouncer(newDebouncerOptions{delay: 150 * time.Millisecond, fire: func() {
		select {
		case a.resultCh <- resizeMsg{}:
		default:
		}
	}})
	go func() {
		for range sigWinch {
			a.width = getWidth()
			resizeDb.Trigger()
		}
	}()

	// Start async initialization
	a.rebuildEffectiveConfig()
	a.startInit()

	// Initial render
	a.render()

	// Start the stdin reader goroutine
	a.startStdinReader()

	// Main event loop — selects on stdin, agent events, and async results
	for {
		// If agent is running, select on all channels.
		// Otherwise, just wait for stdin or async results.
		if a.agent != nil && a.agentRunning {
			select {
			case ch, ok := <-a.stdinCh:
				if !ok {
					goto done
				}
				if a.handleInputByte(ch) {
					goto done
				}
			case event, ok := <-a.agent.Events():
				if ok {
					a.handleAgentEvent(event)
				}
				a.drainResults()
				a.drainAgentEvents()
			case result := <-a.resultCh:
				a.handleResult(result)
				a.drainAgentEvents()
			}
		} else if a.agent != nil && a.hasActiveSubAgents() {
			// Main agent stopped but sub-agents are still running —
			// keep draining their events so the display stays live.
			select {
			case ch, ok := <-a.stdinCh:
				if !ok {
					goto done
				}
				if a.handleInputByte(ch) {
					goto done
				}
			case event, ok := <-a.agent.Events():
				if ok {
					a.handleAgentEvent(event)
				} else {
					// Channel closed while sub-agents are tracked as active.
					// Their "done" events were lost — force-complete them so
					// the UI stops showing spinners.
					a.forceCompleteSubAgents()
				}
				a.drainResults()
				a.drainAgentEvents()
			case result := <-a.resultCh:
				a.handleResult(result)
				a.drainAgentEvents()
			}
		} else {
			select {
			case ch, ok := <-a.stdinCh:
				if !ok {
					goto done
				}
				if a.handleInputByte(ch) {
					goto done
				}
			case result := <-a.resultCh:
				a.handleResult(result)
			}
		}
	}
done:

	a.cleanup()
	return nil
}

func (a *App) handleInputByte(ch byte) bool {
	opts := handleByteOptions{ch: ch, stdinCh: a.stdinCh, readByte: a.readByte}
	if isInterruptByte(ch) {
		if a.handleByte(opts) {
			return true
		}
		a.drainResults()
		a.drainAgentEvents()
		return false
	}
	a.drainResults()
	a.drainAgentEvents()
	return a.handleByte(opts)
}

// Attachment, clipboard, tmp-dir, and startup-fanout helpers live in wiring.go.

func (a *App) handleApprovalByte(ch byte) {
	switch ch {
	case 'y', 'Y':
		a.awaitingApproval = false
		var waitDur time.Duration
		if !a.approvalPauseStart.IsZero() {
			waitDur = time.Since(a.approvalPauseStart)
			a.approvalPausedTotal += waitDur
			a.approvalPauseStart = time.Time{}
		}
		if a.traceCollector != nil && a.approvalToolID != "" {
			a.traceCollector.AddApproval(AddApprovalOptions{toolID: a.approvalToolID, desc: a.approvalDesc, approved: true, waitDur: waitDur})
		}
		// Restart tool timer ticker (frozen during approval).
		if !a.toolStartTime.IsZero() && a.toolTimer == nil {
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
		if a.agent != nil {
			a.agent.Approve(ApprovalResponse{Approved: true})
		}
		a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Approved"})
		a.render()
	case 'n', 'N':
		a.awaitingApproval = false
		var waitDur time.Duration
		if !a.approvalPauseStart.IsZero() {
			waitDur = time.Since(a.approvalPauseStart)
			a.approvalPausedTotal += waitDur
			a.approvalPauseStart = time.Time{}
		}
		if a.traceCollector != nil && a.approvalToolID != "" {
			a.traceCollector.AddApproval(AddApprovalOptions{toolID: a.approvalToolID, desc: a.approvalDesc, approved: false, waitDur: waitDur})
		}
		if a.agent != nil {
			a.agent.Approve(ApprovalResponse{Approved: false})
		}
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "Denied"})
		a.render()
	}
}

func (a *App) handleEnter() {
	// Text prompt active — submit to callback.
	if a.promptCallback != nil {
		val := strings.TrimSpace(a.inputValue())
		cb := a.promptCallback
		a.promptLabel = ""
		a.promptCallback = nil
		a.resetInput()
		if val != "" {
			cb(val)
		}
		a.renderInput()
		return
	}

	// Autocomplete first
	if matches := a.autocompleteMatches(); len(matches) > 0 {
		idx := a.autocompleteIdx
		if idx >= len(matches) {
			idx = 0
		}
		val := matches[idx]
		a.autocompleteIdx = 0
		a.resetInput()
		a.handleCommand(val)
		return
	}

	val := strings.TrimSpace(strings.ReplaceAll(a.inputValue(), "\r", ""))

	// /clear is allowed even while the agent is running — it interrupts the
	// in-flight work and wipes the conversation.
	if a.agentRunning {
		if strings.HasPrefix(val, "/") && strings.Fields(val)[0] == "/clear" {
			a.resetInput()
			a.handleCommand(val)
		}
		return
	}

	if val == "" {
		return
	}

	a.agentElapsed = 0

	if a.history != nil {
		a.history.Add(val)
	}

	// Try to attach file paths that weren't caught by bracketed paste.
	// Some terminals (e.g. Zed) send drag-and-drop paths as regular input
	// instead of wrapping them in paste markers.
	val = a.tryAttachPaths(val)

	if strings.HasPrefix(val, "/") {
		a.resetInput()
		a.handleCommand(val)
		return
	}

	display := expandPastes(expandPastesOptions{s: val, store: a.pasteStore})
	content := expandAttachments(expandAttachmentsOptions{s: display, store: a.attachments})
	a.resetInput()
	a.pasteStore = nil
	a.pasteCount = 0
	a.attachments = nil
	a.attachmentCount = 0

	if a.langdagClient == nil {
		a.messages = append(a.messages, chatMessage{kind: msgUser, content: display, leadBlank: true})
		a.messages = append(a.messages, chatMessage{kind: msgError, content: configMissingAPIKeyMessage})
		a.render()
		return
	}

	a.messages = append(a.messages, chatMessage{kind: msgUser, content: display, leadBlank: true})
	if !modelsReadyForAgent(a.effectiveModelConfig()) {
		a.messages = appendMissingModelMessageIfNeeded(a.messages)
		a.render()
		return
	}
	if a.backend == backendContainer && !a.containerReady {
		a.messages = append(a.messages, chatMessage{kind: msgInfo, content: "Container is still starting — the agent won't have bash or file tools until it's ready."})
	}
	if a.backend == backendCPSL && !a.cpslReady {
		a.messages = append(a.messages, chatMessage{kind: msgInfo, content: "Local sandbox is still starting — the agent won't have Luau tools until it's ready."})
		a.render()
		return
	}
	a.startAgent(content)
	a.render()
}

// startInit lives in wiring.go.

func (a *App) drainResults() {
	for {
		select {
		case result := <-a.resultCh:
			a.handleResult(result)
		default:
			return
		}
	}
}

type containerRetryMessageOptions struct {
	err            error
	retryInSeconds int
}

func containerRetryMessage(opts containerRetryMessageOptions) chatMessage {
	details := containerRetryDetails(opts.err)
	retryText := "retrying…"
	if opts.retryInSeconds > 0 {
		retryText = fmt.Sprintf("retry in %ds…", opts.retryInSeconds)
	}
	contentParts := append([]string{}, details...)
	contentParts = append(contentParts, retryText)
	blocks := make([]inlineBlock, 0, len(contentParts))
	for _, part := range contentParts {
		blocks = append(blocks, styledInlineBlock(styledInlineBlockOptions{style: "\033[31;3m", text: part}))
	}
	return chatMessage{
		kind:         msgError,
		content:      strings.Join(contentParts, " "),
		inlineBlocks: blocks,
	}
}

func containerRetryDetails(err error) []string {
	if cerr, ok := err.(*ContainerError); ok {
		switch cerr.Code {
		case ErrDockerNotFound:
			return []string{"Docker is not installed.", "Install Docker and try again."}
		case ErrDockerNotRunning:
			return []string{"Docker is not running.", "Start Docker and try again."}
		}
	}
	if err != nil {
		return []string{err.Error()}
	}
	return []string{"Docker is unavailable."}
}

func containerRecoveredMessage() chatMessage {
	return chatMessage{
		kind:    msgSuccess,
		content: "Docker available",
		inlineBlocks: []inlineBlock{
			styledInlineBlock(styledInlineBlockOptions{style: "\033[32;3m", text: "Docker available"}),
		},
	}
}

func (a *App) upsertContainerRetryMessage(msg chatMessage) {
	if a.containerRetryMsgActive && a.containerRetryMsgIdx >= 0 && a.containerRetryMsgIdx < len(a.messages) {
		a.messages[a.containerRetryMsgIdx] = msg
		return
	}
	a.messages = append(a.messages, msg)
	a.containerRetryMsgIdx = len(a.messages) - 1
	a.containerRetryMsgActive = true
}

func (a *App) completeContainerRetryMessage(msg chatMessage) {
	if !a.containerRetryMsgActive || a.containerRetryMsgIdx < 0 || a.containerRetryMsgIdx >= len(a.messages) {
		return
	}
	a.messages[a.containerRetryMsgIdx] = msg
	a.containerRetryMsgActive = false
}

func (a *App) handleResult(result any) {
	switch msg := result.(type) {
	case toolTimerTickMsg:
		a.render()
		return
	case agentTickMsg:
		if a.agentRunning {
			elapsed := a.agentElapsedTime()
			a.agentTextIndex = int(elapsed.Seconds()/4) % len(funnyTexts)
			// Lerp displayed tokens toward main-agent totals.
			a.agentDisplayInTok += (float64(a.mainAgentInputTokens) - a.agentDisplayInTok) * 0.15
			a.agentDisplayOutTok += (float64(a.mainAgentOutputTokens) - a.agentDisplayOutTok) * 0.15
		}
		if a.awaitingApproval {
			a.renderInput() // Only redraw input area; leave block rows (tool timer) frozen.
		} else {
			a.render()
		}
		return
	case configTickMsg:
		if a.cfgActive && a.hasUnsavedConfigDrafts() {
			a.renderInput()
		}
		return
	case ctrlCExpiredMsg:
		_ = msg
		if a.ctrlCHint && time.Since(a.ctrlCTime) >= interruptTapWindow {
			a.ctrlCHint = false
			a.ctrlCTime = time.Time{}
			a.renderInput()
		}
		return
	case escExpiredMsg:
		_ = msg
		if a.escHint && time.Since(a.escTime) >= interruptTapWindow {
			a.escHint = false
			a.escTime = time.Time{}
			a.renderInput()
		}
		return

	case sweScoresMsg:
		a.sweLoaded = true
		if msg.err == nil {
			a.sweScores = msg.scores
			if a.models != nil {
				matchSWEScores(matchSWEScoresOptions{models: a.models, scores: a.sweScores})
			}
		}

	case catalogMsg:
		if msg.catalog != nil {
			if msg.source != "" {
				log.Printf("model catalog loaded from %s", msg.source)
			}
			for _, diagnostic := range msg.diagnostics {
				log.Printf("model catalog diagnostic: %s: %s", diagnostic.Code, diagnostic.Message)
			}
			a.modelCatalog = msg.catalog
			a.models = modelsFromCatalogPreservingDynamic(modelsFromCatalogPreservingDynamicOptions{
				catalog: msg.catalog,
				current: a.models,
			})
			if a.sweLoaded && a.sweScores != nil {
				matchSWEScores(matchSWEScoresOptions{models: a.models, scores: a.sweScores})
			}
			alreadyShown := a.shownInitialModel
			a.maybeShowInitialModels()
			if alreadyShown {
				a.refreshResolvedModelDisplay()
			}
			// Fetch local/dynamic provider models async.
			if a.config.ollamaBaseURL() != "" && !a.ollamaFetched {
				go func() { a.resultCh <- fetchOllamaModelsCmd(a.config.ollamaBaseURL()) }()
			}
			if a.config.openRouterAPIKey() != "" && !a.openRouterFetched {
				go func() { a.resultCh <- fetchOpenRouterModelsCmd(a.config.openRouterAPIKey()) }()
			}
			if !a.appleFetched {
				go func() { a.resultCh <- fetchAppleModelsCmd(a.config.appleFMBaseURL()) }()
			}
			cfg := a.config
			models := a.models
			catalog := a.modelCatalog
			provider := cfg.defaultLangdagProviderForModels(models)
			go func() {
				client, err := newLangdagClientForModelsWithCatalog(newLangdagClientForModelsWithCatalogOptions{
					cfg:     cfg,
					models:  models,
					catalog: catalog,
				})
				a.resultCh <- langdagReadyMsg{client: client, provider: provider, runtimeApple: hasRuntimeAppleModels(models), err: err}
			}()
		}
	case ollamaModelsMsg:
		a.ollamaFetched = true
		if len(msg.models) > 0 {
			base := modelsFromCatalog(a.modelCatalog)
			dynamic := dynamicModelsForProviders(dynamicModelsForProvidersOptions{
				models:    a.models,
				providers: map[string]bool{ProviderOpenRouter: true, ProviderApple: true},
			})
			dynamic = append(dynamic, msg.models...)
			a.models = mergeDynamicModels(mergeDynamicModelsOptions{base: base, dynamic: dynamic})
			if a.sweLoaded && a.sweScores != nil {
				matchSWEScores(matchSWEScoresOptions{models: a.models, scores: a.sweScores})
			}
		}
		alreadyShown := a.shownInitialModel
		a.maybeShowInitialModels()
		if alreadyShown {
			a.refreshResolvedModelDisplay()
		}
	case openRouterModelsMsg:
		a.openRouterFetched = true
		if len(msg.models) > 0 {
			base := modelsFromCatalog(a.modelCatalog)
			dynamic := dynamicModelsForProviders(dynamicModelsForProvidersOptions{
				models:    a.models,
				providers: map[string]bool{ProviderOllama: true, ProviderApple: true},
			})
			dynamic = append(dynamic, msg.models...)
			a.models = mergeDynamicModels(mergeDynamicModelsOptions{base: base, dynamic: dynamic})
			if a.sweLoaded && a.sweScores != nil {
				matchSWEScores(matchSWEScoresOptions{models: a.models, scores: a.sweScores})
			}
		}
		alreadyShown := a.shownInitialModel
		a.maybeShowInitialModels()
		if alreadyShown {
			a.refreshResolvedModelDisplay()
		}
	case appleModelsMsg:
		a.handleAppleModelsMsg(msg)
	case draftAppleModelsMsg:
		a.handleDraftAppleModelsMsg(msg)
	case openPickerMsg:
		if a.cfgActive {
			a.doOpenConfigModelPicker(doOpenConfigModelPickerOptions{models: a.models, getCurrentID: msg.getCurrentID, onSelect: msg.onSelect})
		}

	case langdagReadyMsg:
		a.handleLangdagReadyMsg(msg)

	case statusInfoMsg:
		a.status = msg.info

	case commitInfoMsg:
		a.status.Branch = msg.branch
		a.status.HasUpstream = msg.hasUpstream
		a.status.Behind = msg.behind
		a.status.Ahead = msg.ahead
		a.status.DiffAdd = msg.diffAdd
		a.status.DiffDel = msg.diffDel

	case projectSnapshotMsg:
		a.projectSnap = &msg.snapshot

	case workspaceMsg:
		a.worktreePath = msg.worktreePath
		a.repoRoot = msg.repoRoot
		if a.models != nil {
			a.projectConfig = loadProjectConfigForModels(loadProjectConfigForModelsOptions{repoRoot: a.projectConfigRoot(), models: a.models})
		} else {
			a.projectConfig = loadRawProjectConfig(a.projectConfigRoot())
		}
		a.rebuildEffectiveConfig()
		a.configReady = true
		a.initAppDebugLog()
		a.history = newHistory(newHistoryOptions{projectDir: msg.worktreePath, maxSize: a.config.effectiveMaxHistory()})
		a.history.Load()
		a.maybeShowInitialModels()
		wtPath := msg.worktreePath
		go func() { a.resultCh <- fetchStatusCmd(wtPath) }()
		go func() { a.resultCh <- fetchProjectSnapshot(wtPath) }()
		a.startBackendForWorkspace(wtPath)
		go cleanupTmpDir(wtPath)
		go cleanupAgentOutputDir(wtPath)
		// Start periodic commit info refresh (only if git is available)
		if _, err := exec.LookPath("git"); err == nil {
			a.commitInfoTicker = time.NewTicker(15 * time.Second)
			go func(ticker *time.Ticker, ch chan any, path string) {
				for range ticker.C {
					ch <- fetchCommitInfo(path)
				}
			}(a.commitInfoTicker, a.resultCh, wtPath)
		}

	case containerReadyMsg:
		a.container = msg.client
		if msg.worktreePath != "" {
			a.worktreePath = msg.worktreePath
		}
		if msg.imageName != "" {
			a.containerImage = msg.imageName
		}
		a.containerReady = true
		a.containerErr = nil
		a.completeContainerRetryMessage(containerRecoveredMessage())
		if cid := msg.client.ContainerID(); cid != "" {
			shortID := cid
			if len(shortID) > 12 {
				shortID = shortID[:12]
			}
			a.containerStatusText = shortID
		}

	case cpslReadyMsg:
		a.cpslWorker = msg.client
		if msg.worktreePath != "" {
			a.worktreePath = msg.worktreePath
		}
		a.cpslReady = true
		a.cpslErr = nil
		a.cpslStatusText = "ready (/workdir)"

	case cpslErrMsg:
		a.cpslErr = msg.err
		a.cpslReady = false
		a.cpslStatusText = "error"
		if msg.err != nil {
			a.messages = append(a.messages, chatMessage{kind: msgError, content: msg.err.Error()})
		}

	case cpslStatusMsg:
		a.cpslStatusText = msg.text

	case containerStatusMsg:
		a.containerStatusText = msg.text

	case containerRetryMsg:
		a.containerErr = msg.err
		a.upsertContainerRetryMessage(containerRetryMessage(containerRetryMessageOptions{err: msg.err, retryInSeconds: msg.retryInSeconds}))

	case containerRetryRecoveredMsg:
		a.containerErr = nil
		a.completeContainerRetryMessage(containerRecoveredMessage())

	case containerErrMsg:
		a.containerErr = msg.err
		a.containerRetryMsgActive = false
		a.messages = append(a.messages, chatMessage{kind: msgError, content: msg.err.Error()})

	case worktreeListMsg:
		if msg.err != nil {
			a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Error listing worktrees: %v", msg.err)})
		}

	case branchListMsg:
		if msg.err != nil {
			a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Error listing branches: %v", msg.err)})
		}

	case branchCheckoutMsg:
		if msg.err != nil {
			a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Checkout failed: %v", msg.err)})
		} else {
			a.status.Branch = msg.branch
			a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: fmt.Sprintf("Switched to branch '%s'", msg.branch)})
		}

	case updateAvailableMsg:
		if msg.err == nil && msg.version != "" {
			a.updateAvailable = msg.version
			current := Version
			if current == "dev" {
				current = "dev"
			}
			a.messages = append(a.messages, chatMessage{
				kind:    msgInfo,
				content: fmt.Sprintf("Update available: v%s (current: %s). Run /update to upgrade.", msg.version, current),
			})
		}

	case updateCompleteMsg:
		if msg.err != nil {
			a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Update failed: %v", msg.err)})
		} else {
			ver := a.updateAvailable
			a.updateAvailable = ""
			a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: fmt.Sprintf("Updated to v%s. Restart herm to use the new version.", ver)})
		}

	case resizeMsg:
		a.width = getWidth() // re-read in case of further changes
		a.renderFull()
		return
	}

	a.render()
}

// ─── Cleanup ───

func (a *App) cleanup() {
	if a.commitInfoTicker != nil {
		a.commitInfoTicker.Stop()
		a.commitInfoTicker = nil
	}
	if a.toolTimer != nil {
		a.toolTimer.Stop()
		a.toolTimer = nil
	}
	if a.configTicker != nil {
		a.stopConfigTicker()
	}
	if a.traceCollector != nil {
		a.traceCollector.Finalize()
		if err := a.traceCollector.FlushToFile(a.traceFilePath); err != nil {
			fmt.Fprintf(os.Stderr, "debug: failed to write trace: %v\n", err)
		}
		a.traceCollector = nil
	}
	close(a.stopCh)
	if a.agent != nil {
		a.agent.Cancel()
	}
	if a.container != nil {
		_ = a.container.Stop()
	}
	if a.cpslWorker != nil {
		_ = a.cpslWorker.Close()
	}
	if a.langdagClient != nil {
		_ = a.langdagClient.Close()
	}
	if a.worktreePath != "" {
		_ = unlockWorktree(a.worktreePath)
	}
}
