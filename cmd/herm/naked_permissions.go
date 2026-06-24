// naked_permissions.go implements naked-mode approval persistence and parsing helpers.
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

func nakedPermissionsPath(workspace string) string {
	return filepath.Join(workspace, configDir, nakedPermissionsFile)
}

type nakedPermissionStore struct {
	path      string
	workspace string
	mu        sync.Mutex
	once      nakedPermissionSet
}

type newNakedPermissionStoreOptions struct {
	path      string
	workspace string
}

func newNakedPermissionStore(opts newNakedPermissionStoreOptions) *nakedPermissionStore {
	if opts.path == "" {
		return nil
	}
	workspace, _ := filepath.Abs(opts.workspace)
	return &nakedPermissionStore{path: opts.path, workspace: workspace}
}

type nakedPermissionFile struct {
	Version         int        `json:"version"`
	Commands        []string   `json:"commands"`
	CommandPrefixes [][]string `json:"command_prefixes,omitempty"`
	CommandRegexes  []string   `json:"command_regexes,omitempty"`
	Paths           []string   `json:"paths,omitempty"`
	ReadPaths       []string   `json:"read_paths,omitempty"`
	WritePaths      []string   `json:"write_paths,omitempty"`
	PathRegexes     []string   `json:"path_regexes,omitempty"`
	Network         bool       `json:"network,omitempty"`
}

type nakedPermissionSet struct {
	Commands   map[string]bool
	Paths      map[string]bool
	ReadPaths  map[string]bool
	WritePaths map[string]bool
	Network    bool
}

type loadedNakedPermissions struct {
	file            nakedPermissionFile
	commands        map[string]bool
	commandPrefixes [][]string
	commandRegexes  []*regexp.Regexp
	paths           map[string]bool
	readPaths       map[string]bool
	writePaths      map[string]bool
	pathRegexes     []*regexp.Regexp
	network         bool
	invalidRegexes  []string
	invalidPatterns []string
}

type recordRequestedPermissionsOptions struct {
	permissions bashAdditionalPermissions
	remember    bool
}

func (s *nakedPermissionStore) RequiresApproval(command string) bool {
	if s == nil || strings.TrimSpace(command) == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	permissions, err := s.loadLocked()
	if err != nil {
		return true
	}
	for _, segment := range commandApprovalSegments(command) {
		if !s.commandAllowedLocked(commandAllowedLockedOptions{permissions: permissions, command: segment}) {
			return true
		}
	}
	for _, path := range commandExternalPaths(commandExternalPathsOptions{command: command, workspace: s.workspace}) {
		if !s.pathAllowedLocked(pathAllowedLockedOptions{permissions: permissions, path: path}) {
			return true
		}
	}
	return false
}

func (s *nakedPermissionStore) RecordApproval(opts recordCommandApprovalOptions) error {
	command := opts.command
	if s == nil || strings.TrimSpace(command) == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if opts.remember {
		permissions, err := s.loadLocked()
		if err != nil {
			return err
		}
		changed := false
		for _, segment := range commandApprovalSegments(command) {
			if segment != "" && !permissions.commands[segment] {
				permissions.commands[segment] = true
				changed = true
			}
		}
		for _, prefix := range opts.commandPrefixes {
			if appendUniqueCommandPrefix(appendUniqueCommandPrefixOptions{prefixes: &permissions.commandPrefixes, rule: prefix}) {
				changed = true
			}
		}
		for _, path := range commandExternalPaths(commandExternalPathsOptions{command: command, workspace: s.workspace}) {
			if path != "" && !permissions.paths[path] {
				permissions.paths[path] = true
				changed = true
			}
		}
		if !changed {
			return nil
		}
		return s.saveLocked(permissions)
	}

	for _, segment := range commandApprovalSegments(command) {
		if segment != "" {
			if s.once.Commands == nil {
				s.once.Commands = map[string]bool{}
			}
			s.once.Commands[segment] = true
		}
	}
	for _, path := range commandExternalPaths(commandExternalPathsOptions{command: command, workspace: s.workspace}) {
		if path != "" {
			if s.once.Paths == nil {
				s.once.Paths = map[string]bool{}
			}
			s.once.Paths[path] = true
		}
	}
	return nil
}

func (s *nakedPermissionStore) RequestedPermissionsRequireApproval(permissions bashAdditionalPermissions) bool {
	if s == nil || permissions.empty() {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	loaded, err := s.loadLocked()
	if err != nil {
		return true
	}
	if permissions.Network.Enabled && !loaded.network && !s.once.Network {
		return true
	}
	for _, path := range permissions.FileSystem.Read {
		if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
			if !loaded.readPaths[normalized] && !loaded.writePaths[normalized] && !s.once.ReadPaths[normalized] && !s.once.WritePaths[normalized] && !s.once.Paths[normalized] {
				return true
			}
		}
	}
	for _, path := range permissions.FileSystem.Write {
		if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
			if !loaded.writePaths[normalized] && !s.once.WritePaths[normalized] && !s.once.Paths[normalized] {
				return true
			}
		}
	}
	return false
}

func (s *nakedPermissionStore) RecordRequestedPermissions(opts recordRequestedPermissionsOptions) error {
	if s == nil || opts.permissions.empty() {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if opts.remember {
		permissions, err := s.loadLocked()
		if err != nil {
			return err
		}
		changed := false
		if opts.permissions.Network.Enabled && !permissions.network {
			permissions.network = true
			changed = true
		}
		for _, path := range opts.permissions.FileSystem.Read {
			if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
				if !permissions.readPaths[normalized] {
					permissions.readPaths[normalized] = true
					changed = true
				}
			}
		}
		for _, path := range opts.permissions.FileSystem.Write {
			if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
				if !permissions.writePaths[normalized] {
					permissions.writePaths[normalized] = true
					changed = true
				}
			}
		}
		if !changed {
			return nil
		}
		return s.saveLocked(permissions)
	}

	if opts.permissions.Network.Enabled {
		s.once.Network = true
	}
	for _, path := range opts.permissions.FileSystem.Read {
		if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
			if s.once.ReadPaths == nil {
				s.once.ReadPaths = map[string]bool{}
			}
			s.once.ReadPaths[normalized] = true
		}
	}
	for _, path := range opts.permissions.FileSystem.Write {
		if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
			if s.once.WritePaths == nil {
				s.once.WritePaths = map[string]bool{}
			}
			s.once.WritePaths[normalized] = true
		}
	}
	return nil
}

func (s *nakedPermissionStore) FinishRequestedPermissionsOnce() {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.once.ReadPaths = nil
	s.once.WritePaths = nil
	s.once.Network = false
}

func (s *nakedPermissionStore) FinishApproval(command string) {
	if s == nil || strings.TrimSpace(command) == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, segment := range commandApprovalSegments(command) {
		delete(s.once.Commands, segment)
	}
	for _, path := range commandExternalPaths(commandExternalPathsOptions{command: command, workspace: s.workspace}) {
		delete(s.once.Paths, path)
	}
}

func (s *nakedPermissionStore) AllowedExternalPaths(command string) []string {
	if s == nil || strings.TrimSpace(command) == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	permissions, err := s.loadLocked()
	if err != nil {
		return nil
	}
	var paths []string
	for _, path := range commandExternalPaths(commandExternalPathsOptions{command: command, workspace: s.workspace}) {
		if s.pathAllowedLocked(pathAllowedLockedOptions{permissions: permissions, path: path}) {
			paths = append(paths, path)
		}
	}
	return uniqueSortedStrings(paths)
}

func (s *nakedPermissionStore) RequestedSandboxPermissions() (readPaths, writePaths []string, network bool) {
	if s == nil {
		return nil, nil, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	permissions, err := s.loadLocked()
	if err != nil {
		return nil, nil, false
	}
	for path := range permissions.readPaths {
		readPaths = append(readPaths, path)
	}
	for path := range permissions.writePaths {
		writePaths = append(writePaths, path)
	}
	for path := range s.once.ReadPaths {
		readPaths = append(readPaths, path)
	}
	for path := range s.once.Paths {
		writePaths = append(writePaths, path)
	}
	for path := range s.once.WritePaths {
		writePaths = append(writePaths, path)
	}
	return uniqueSortedStrings(readPaths), uniqueSortedStrings(writePaths), permissions.network || s.once.Network
}

type commandAllowedLockedOptions struct {
	permissions loadedNakedPermissions
	command     string
}

func (s *nakedPermissionStore) commandAllowedLocked(opts commandAllowedLockedOptions) bool {
	if opts.permissions.commands[opts.command] || s.once.Commands[opts.command] {
		return true
	}
	if commandMatchesAnyPrefix(commandMatchesAnyPrefixOptions{command: opts.command, prefixes: opts.permissions.commandPrefixes}) {
		return true
	}
	for _, re := range opts.permissions.commandRegexes {
		if re.MatchString(opts.command) {
			return true
		}
	}
	return false
}

type pathAllowedLockedOptions struct {
	permissions loadedNakedPermissions
	path        string
}

func (s *nakedPermissionStore) pathAllowedLocked(opts pathAllowedLockedOptions) bool {
	if opts.permissions.paths[opts.path] || s.once.Paths[opts.path] {
		return true
	}
	if opts.permissions.readPaths[opts.path] || opts.permissions.writePaths[opts.path] || s.once.ReadPaths[opts.path] || s.once.WritePaths[opts.path] {
		return true
	}
	for _, re := range opts.permissions.pathRegexes {
		if re.MatchString(opts.path) {
			return true
		}
	}
	return false
}

func (s *nakedPermissionStore) loadLocked() (loadedNakedPermissions, error) {
	loaded := loadedNakedPermissions{
		file: nakedPermissionFile{
			Version: 1,
		},
		commands:   map[string]bool{},
		paths:      map[string]bool{},
		readPaths:  map[string]bool{},
		writePaths: map[string]bool{},
	}
	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return loaded, nil
	}
	if err != nil {
		return loaded, err
	}
	if err := json.Unmarshal(data, &loaded.file); err != nil {
		return loaded, err
	}
	for _, command := range loaded.file.Commands {
		command = strings.TrimSpace(command)
		if command != "" {
			loaded.commands[command] = true
		}
	}
	for _, prefix := range loaded.file.CommandPrefixes {
		appendUniqueCommandPrefix(appendUniqueCommandPrefixOptions{prefixes: &loaded.commandPrefixes, rule: prefix})
	}
	for _, path := range loaded.file.Paths {
		if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
			loaded.paths[normalized] = true
		}
	}
	for _, path := range loaded.file.ReadPaths {
		if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
			loaded.readPaths[normalized] = true
		}
	}
	for _, path := range loaded.file.WritePaths {
		if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: s.workspace, path: path}); ok {
			loaded.writePaths[normalized] = true
		}
	}
	loaded.network = loaded.file.Network
	loaded.commandRegexes, loaded.invalidRegexes = compileNakedRegexes(loaded.file.CommandRegexes)
	loaded.pathRegexes, loaded.invalidPatterns = compileNakedRegexes(loaded.file.PathRegexes)
	return loaded, nil
}

func (s *nakedPermissionStore) saveLocked(permissions loadedNakedPermissions) error {
	commands := make([]string, 0, len(permissions.commands))
	for command := range permissions.commands {
		commands = append(commands, command)
	}
	sort.Strings(commands)

	paths := make([]string, 0, len(permissions.paths))
	for path := range permissions.paths {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	readPaths := make([]string, 0, len(permissions.readPaths))
	for path := range permissions.readPaths {
		readPaths = append(readPaths, path)
	}
	sort.Strings(readPaths)
	writePaths := make([]string, 0, len(permissions.writePaths))
	for path := range permissions.writePaths {
		writePaths = append(writePaths, path)
	}
	sort.Strings(writePaths)

	file := permissions.file
	file.Version = 1
	file.Commands = commands
	file.CommandPrefixes = sortedCommandPrefixes(permissions.commandPrefixes)
	file.Paths = paths
	file.ReadPaths = readPaths
	file.WritePaths = writePaths
	file.Network = permissions.network
	data, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(s.path, append(data, '\n'), 0o644)
}

func normalizeCommandPrefixRule(rule []string) []string {
	var normalized []string
	for _, part := range rule {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		normalized = append(normalized, part)
	}
	return normalized
}

type appendUniqueCommandPrefixOptions struct {
	prefixes *[][]string
	rule     []string
}

func appendUniqueCommandPrefix(opts appendUniqueCommandPrefixOptions) bool {
	normalized := normalizeCommandPrefixRule(opts.rule)
	if len(normalized) == 0 {
		return false
	}
	key := commandPrefixKey(normalized)
	for _, existing := range *opts.prefixes {
		if commandPrefixKey(existing) == key {
			return false
		}
	}
	*opts.prefixes = append(*opts.prefixes, normalized)
	return true
}

func sortedCommandPrefixes(prefixes [][]string) [][]string {
	if len(prefixes) == 0 {
		return nil
	}
	out := make([][]string, 0, len(prefixes))
	for _, prefix := range prefixes {
		normalized := normalizeCommandPrefixRule(prefix)
		if len(normalized) == 0 {
			continue
		}
		out = append(out, append([]string(nil), normalized...))
	}
	sort.Slice(out, func(i, j int) bool {
		return commandPrefixKey(out[i]) < commandPrefixKey(out[j])
	})
	return out
}

func commandPrefixKey(prefix []string) string {
	return strings.Join(prefix, "\x00")
}

type commandMatchesAnyPrefixOptions struct {
	command  string
	prefixes [][]string
}

func commandMatchesAnyPrefix(opts commandMatchesAnyPrefixOptions) bool {
	words := shellWords(opts.command)
	if len(words) == 0 {
		return false
	}
	for _, prefix := range opts.prefixes {
		if commandWordsHavePrefix(commandWordsHavePrefixOptions{words: words, prefix: prefix}) {
			return true
		}
	}
	return false
}

type commandWordsHavePrefixOptions struct {
	words  []string
	prefix []string
}

func commandWordsHavePrefix(opts commandWordsHavePrefixOptions) bool {
	prefix := normalizeCommandPrefixRule(opts.prefix)
	if len(prefix) == 0 || len(prefix) > len(opts.words) {
		return false
	}
	for i, part := range prefix {
		if opts.words[i] != part {
			return false
		}
	}
	return true
}

func compileNakedRegexes(patterns []string) ([]*regexp.Regexp, []string) {
	var regexes []*regexp.Regexp
	var invalid []string
	for _, pattern := range patterns {
		pattern = strings.TrimSpace(pattern)
		if pattern == "" {
			continue
		}
		re, err := regexp.Compile(pattern)
		if err != nil {
			invalid = append(invalid, pattern)
			continue
		}
		regexes = append(regexes, re)
	}
	return regexes, invalid
}

func commandApprovalSegments(command string) []string {
	var segments []string
	var b strings.Builder
	var quote rune
	escaped := false
	skipNext := false
	flush := func() {
		segment := strings.TrimSpace(b.String())
		if segment != "" {
			segments = append(segments, segment)
		}
		b.Reset()
	}

	for i, r := range command {
		if skipNext {
			skipNext = false
			continue
		}
		if escaped {
			b.WriteRune(r)
			escaped = false
			continue
		}
		if r == '\\' && quote != '\'' {
			b.WriteRune(r)
			escaped = true
			continue
		}
		if quote != 0 {
			b.WriteRune(r)
			if r == quote {
				quote = 0
			}
			continue
		}
		if r == '\'' || r == '"' {
			quote = r
			b.WriteRune(r)
			continue
		}
		switch r {
		case '\n', ';', '|':
			flush()
			if r == '|' && i+1 < len(command) && command[i+1] == '|' {
				skipNext = true
			}
			continue
		case '&':
			flush()
			if i+1 < len(command) && command[i+1] == '&' {
				skipNext = true
			}
			continue
		case '(', ')':
			if r == '(' && i > 0 && command[i-1] == '$' {
				segment := strings.TrimSpace(strings.TrimSuffix(strings.TrimRight(b.String(), " \t"), "$"))
				b.Reset()
				if segment != "" {
					segments = append(segments, segment)
				}
				continue
			}
			flush()
			continue
		}
		b.WriteRune(r)
	}
	flush()
	if len(segments) == 0 {
		if trimmed := strings.TrimSpace(command); trimmed != "" {
			return []string{trimmed}
		}
	}
	return segments
}

type commandExternalPathsOptions struct {
	command   string
	workspace string
}

func commandExternalPaths(opts commandExternalPathsOptions) []string {
	var paths []string
	for _, word := range shellWords(opts.command) {
		for _, candidate := range pathCandidatesFromShellWord(word) {
			if normalized, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: opts.workspace, path: candidate}); ok {
				paths = append(paths, normalized)
			}
		}
	}
	return uniqueSortedStrings(paths)
}

func pathCandidatesFromShellWord(word string) []string {
	if word == "" {
		return nil
	}
	word = strings.Trim(word, `"'`)
	word = strings.TrimRight(word, `,`)
	var candidates []string
	if isNakedPathCandidate(word) {
		candidates = append(candidates, word)
	}
	if idx := strings.IndexByte(word, '='); idx >= 0 && idx+1 < len(word) {
		value := strings.Trim(word[idx+1:], `"'`)
		if isNakedPathCandidate(value) {
			candidates = append(candidates, value)
		}
	}
	return candidates
}

func isNakedPathCandidate(s string) bool {
	return strings.HasPrefix(s, "/") || strings.HasPrefix(s, "~/") || strings.HasPrefix(s, "../")
}

func shellWords(command string) []string {
	var words []string
	var b strings.Builder
	var quote rune
	escaped := false
	flush := func() {
		if b.Len() == 0 {
			return
		}
		word := strings.TrimSpace(b.String())
		if word != "" {
			words = append(words, word)
		}
		b.Reset()
	}

	for _, r := range command {
		if escaped {
			b.WriteRune(r)
			escaped = false
			continue
		}
		if r == '\\' && quote != '\'' {
			escaped = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
				continue
			}
			b.WriteRune(r)
			continue
		}
		switch r {
		case '\'', '"':
			quote = r
		case ' ', '\t', '\n', ';', '|', '&', '(', ')':
			flush()
		default:
			b.WriteRune(r)
		}
	}
	flush()
	return words
}

type normalizeNakedPathOptions struct {
	workspace string
	path      string
}

func normalizeNakedPath(opts normalizeNakedPathOptions) (string, bool) {
	path := opts.path
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			path = filepath.Join(home, strings.TrimPrefix(path, "~/"))
		}
	}
	if !filepath.IsAbs(path) {
		if opts.workspace == "" {
			return "", false
		}
		path = filepath.Join(opts.workspace, path)
	}
	normalized := filepath.Clean(path)
	if resolved, err := filepath.EvalSymlinks(normalized); err == nil {
		normalized = resolved
	}
	workspace := filepath.Clean(opts.workspace)
	if resolved, err := filepath.EvalSymlinks(workspace); err == nil {
		workspace = resolved
	}
	if normalized == workspace || strings.HasPrefix(normalized, workspace+string(filepath.Separator)) {
		return "", false
	}
	return normalized, true
}

type normalizeNakedExternalPathsOptions struct {
	workspace string
	paths     []string
}

func normalizeNakedExternalPaths(opts normalizeNakedExternalPathsOptions) []string {
	var normalized []string
	for _, path := range opts.paths {
		if p, ok := normalizeNakedPath(normalizeNakedPathOptions{workspace: opts.workspace, path: path}); ok {
			normalized = append(normalized, p)
		}
	}
	return uniqueSortedStrings(normalized)
}

func uniqueSortedStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(values))
	var out []string
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}
