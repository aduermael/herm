// skills.go discovers Codex-style skill packages without prompt-loading full
// contents. Sandboxed backends get a staged /skills tree for lazy reads of
// SKILL.md and package support files.
package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	localSkillsDirName      = ".agents/skills"
	globalSkillsDirName     = ".agents/skills"
	skillDocFileName        = "SKILL.md"
	skillsRuntimeDirName    = "skills-runtime"
	skillsVirtualRoot       = "/skills"
	skillDescriptionMaxRune = 260
)

// Skill is the prompt-facing metadata for a lazily loaded skill.
type Skill struct {
	Name        string
	Description string
	Path        string

	runtimeName string
	sourcePath  string
	sourceDir   string
	sourceKind  skillSourceKind
	scope       skillScope
}

type skillScope string

const (
	skillScopeGlobal skillScope = "global"
	skillScopeLocal  skillScope = "local"
)

type skillSourceKind int

const (
	skillSourceFile skillSourceKind = iota
	skillSourceDirectory
)

type skillRoot struct {
	Path  string
	Scope skillScope
}

type skillFrontMatter struct {
	Name        string         `yaml:"name"`
	Description string         `yaml:"description"`
	WhenToUse   string         `yaml:"when_to_use"`
	Metadata    map[string]any `yaml:"metadata"`
}

// discoverSkills returns project-local skills from .agents/skills and user
// global skills from ~/.agents/skills. Local skills override global skills with
// the same name. The legacy .herm/skills path is intentionally ignored.
func discoverSkills(workspace string) ([]Skill, error) {
	return discoverSkillsFromRoots(defaultSkillRoots(workspace))
}

func defaultSkillRoots(workspace string) []skillRoot {
	var roots []skillRoot
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		roots = append(roots, skillRoot{
			Path:  filepath.Join(home, globalSkillsDirName),
			Scope: skillScopeGlobal,
		})
	}
	if workspace != "" {
		roots = append(roots, skillRoot{
			Path:  filepath.Join(workspace, localSkillsDirName),
			Scope: skillScopeLocal,
		})
	}
	return roots
}

func discoverSkillsFromRoots(roots []skillRoot) ([]Skill, error) {
	byName := map[string]Skill{}
	for _, root := range roots {
		skills, err := discoverSkillsInRoot(root)
		if err != nil {
			return nil, err
		}
		for _, skill := range skills {
			byName[strings.ToLower(skill.Name)] = skill
		}
	}

	skills := make([]Skill, 0, len(byName))
	for _, skill := range byName {
		skills = append(skills, skill)
	}
	sort.Slice(skills, func(i, j int) bool {
		return strings.ToLower(skills[i].Name) < strings.ToLower(skills[j].Name)
	})
	return skills, nil
}

func discoverSkillsInRoot(root skillRoot) ([]Skill, error) {
	entries, err := os.ReadDir(root.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var skills []Skill
	for _, entry := range entries {
		skill, ok := discoverSkillEntry(discoverSkillEntryOptions{root: root, entry: entry})
		if ok {
			skills = append(skills, skill)
		}
	}
	return skills, nil
}

type discoverSkillEntryOptions struct {
	root  skillRoot
	entry os.DirEntry
}

func discoverSkillEntry(opts discoverSkillEntryOptions) (Skill, bool) {
	root := opts.root
	entry := opts.entry
	entryPath := filepath.Join(root.Path, entry.Name())
	defaultName := strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name()))
	sourceKind := skillSourceFile
	sourceDir := filepath.Dir(entryPath)
	skillFile := entryPath

	if entry.IsDir() {
		defaultName = entry.Name()
		sourceKind = skillSourceDirectory
		sourceDir = entryPath
		skillFile = filepath.Join(entryPath, skillDocFileName)
		if info, err := os.Stat(skillFile); err != nil || info.IsDir() {
			return Skill{}, false
		}
	} else if !strings.EqualFold(filepath.Ext(entry.Name()), ".md") {
		return Skill{}, false
	}

	data, err := os.ReadFile(skillFile)
	if err != nil {
		return Skill{}, false
	}
	skill, ok := parseSkillMetadata(parseSkillMetadataOptions{
		raw:         string(data),
		defaultName: defaultName,
	})
	if !ok {
		return Skill{}, false
	}
	skill.runtimeName = safeSkillPathName(safeSkillPathNameOptions{name: skill.Name, fallback: defaultName})
	skill.Path = skillPromptPath(skill.runtimeName)
	skill.sourcePath = skillFile
	skill.sourceDir = sourceDir
	skill.sourceKind = sourceKind
	skill.scope = root.Scope
	return skill, true
}

func skillPromptPath(runtimeName string) string {
	return skillsVirtualRoot + "/" + runtimeName + "/" + skillDocFileName
}

type parseSkillMetadataOptions struct {
	raw         string
	defaultName string
}

func parseSkillMetadata(opts parseSkillMetadataOptions) (Skill, bool) {
	frontMatter, ok := splitMarkdownFrontMatter(opts.raw)
	if !ok {
		return Skill{}, false
	}

	var meta skillFrontMatter
	if err := yaml.Unmarshal([]byte(frontMatter), &meta); err != nil {
		return Skill{}, false
	}

	name := strings.TrimSpace(meta.Name)
	if name == "" {
		name = strings.TrimSpace(opts.defaultName)
	}
	if name == "" {
		return Skill{}, false
	}

	description := metadataString(metadataStringOptions{
		metadata: meta.Metadata,
		key:      "short-description",
	})
	if description == "" {
		description = meta.Description
	}
	if description == "" {
		description = meta.WhenToUse
	}

	return Skill{
		Name:        name,
		Description: shortSkillDescription(description),
	}, true
}

func splitMarkdownFrontMatter(raw string) (string, bool) {
	raw = strings.TrimPrefix(raw, "\ufeff")
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return "", false
	}

	var frontMatter []string
	for _, line := range lines[1:] {
		if strings.TrimSpace(line) == "---" {
			return strings.Join(frontMatter, "\n"), true
		}
		frontMatter = append(frontMatter, line)
	}
	return "", false
}

type metadataStringOptions struct {
	metadata map[string]any
	key      string
}

func metadataString(opts metadataStringOptions) string {
	if opts.metadata == nil {
		return ""
	}
	value, ok := opts.metadata[opts.key]
	if !ok {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return typed
	default:
		return strings.TrimSpace(fmt.Sprint(typed))
	}
}

func shortSkillDescription(description string) string {
	description = strings.Join(strings.Fields(description), " ")
	if len([]rune(description)) <= skillDescriptionMaxRune {
		return description
	}
	runes := []rune(description)
	return strings.TrimSpace(string(runes[:skillDescriptionMaxRune-3])) + "..."
}

var unsafeSkillPathNameChars = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

type safeSkillPathNameOptions struct {
	name     string
	fallback string
}

func safeSkillPathName(opts safeSkillPathNameOptions) string {
	base := strings.TrimSpace(opts.name)
	if base == "" {
		base = opts.fallback
	}
	base = unsafeSkillPathNameChars.ReplaceAllString(base, "-")
	base = strings.Trim(base, ".-")
	if base == "" {
		return "skill"
	}
	return base
}

type prepareRuntimeSkillsOptions struct {
	workspace string
	backend   backendKind
}

func prepareRuntimeSkills(opts prepareRuntimeSkillsOptions) ([]Skill, error) {
	skills, err := discoverSkills(opts.workspace)
	if err != nil {
		return nil, err
	}
	runtimeDir, err := syncSkillsRuntime(syncSkillsRuntimeOptions{
		workspace: opts.workspace,
		skills:    skills,
	})
	if err != nil {
		return nil, err
	}
	if opts.backend == backendNaked {
		for i := range skills {
			skills[i].Path = filepath.Join(runtimeDir, skills[i].runtimeName, skillDocFileName)
		}
	}
	return skills, nil
}

func (a *App) handleSkillsCommand() {
	workspace := a.worktreePath
	if workspace == "" {
		workspace = a.repoRoot
	}
	if workspace == "" {
		if wd, err := os.Getwd(); err == nil {
			workspace = wd
		}
	}

	skills, err := prepareRuntimeSkills(prepareRuntimeSkillsOptions{
		workspace: workspace,
		backend:   a.backend,
	})
	if err != nil {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Error loading skills: %v", err)})
		a.render()
		return
	}
	if len(skills) == 0 {
		a.messages = append(a.messages, chatMessage{kind: msgInfo, content: "No skills found. Add project skills under .agents/skills or global skills under ~/.agents/skills."})
		a.render()
		return
	}

	a.messages = append(a.messages, skillsListMessage(skills))
	a.render()
}

func skillsListMessage(skills []Skill) chatMessage {
	return chatMessage{
		kind:         msgInfo,
		content:      formatSkillsListPlain(skills),
		inlineBlocks: formatSkillsListBlocks(skills),
	}
}

func formatSkillsListPlain(skills []Skill) string {
	var b strings.Builder
	for _, skill := range skills {
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString(skillListLine(skill))
	}
	return b.String()
}

func formatSkillsListBlocks(skills []Skill) []inlineBlock {
	blocks := make([]inlineBlock, 0, len(skills))
	for _, skill := range skills {
		blocks = append(blocks, skillListBlock(skill))
	}
	return blocks
}

func skillListLine(skill Skill) string {
	if skill.Description == "" {
		return skill.Name
	}
	return skill.Name + "  " + skill.Description
}

func skillListBlock(skill Skill) inlineBlock {
	text := styleChatBlue + skill.Name + ansiReset
	if skill.Description != "" {
		text += "  \033[2m" + skill.Description + ansiReset
	}
	return inlineBlock{
		text:        text,
		width:       visibleWidth(text),
		forceOwnRow: true,
	}
}

func skillsRuntimeDir(workspace string) string {
	if workspace == "" {
		return ""
	}
	return filepath.Join(workspace, configDir, skillsRuntimeDirName)
}

func ensureSkillsRuntimeDir(workspace string) (string, error) {
	dir := skillsRuntimeDir(workspace)
	if dir == "" {
		return "", nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

func skillRuntimeMount(workspace string) (MountSpec, bool) {
	dir, err := ensureSkillsRuntimeDir(workspace)
	if err != nil || dir == "" {
		return MountSpec{}, false
	}
	return MountSpec{Source: dir, Destination: skillsVirtualRoot, ReadOnly: true}, true
}

type syncSkillsRuntimeOptions struct {
	workspace string
	skills    []Skill
}

func syncSkillsRuntime(opts syncSkillsRuntimeOptions) (string, error) {
	dir, err := ensureSkillsRuntimeDir(opts.workspace)
	if err != nil || dir == "" {
		return dir, err
	}

	if err := os.RemoveAll(dir); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	for _, skill := range opts.skills {
		dstDir := filepath.Join(dir, skill.runtimeName)
		if err := copySkillToRuntime(copySkillToRuntimeOptions{skill: skill, dstDir: dstDir}); err != nil {
			return "", err
		}
	}
	return dir, nil
}

type copySkillToRuntimeOptions struct {
	skill  Skill
	dstDir string
}

func copySkillToRuntime(opts copySkillToRuntimeOptions) error {
	switch opts.skill.sourceKind {
	case skillSourceDirectory:
		return copySkillDir(copySkillDirOptions{
			srcDir: opts.skill.sourceDir,
			dstDir: opts.dstDir,
		})
	case skillSourceFile:
		if err := os.MkdirAll(opts.dstDir, 0o755); err != nil {
			return err
		}
		return copyRegularFile(copyRegularFileOptions{
			src: opts.skill.sourcePath,
			dst: filepath.Join(opts.dstDir, skillDocFileName),
		})
	default:
		return nil
	}
}

type copySkillDirOptions struct {
	srcDir string
	dstDir string
}

func copySkillDir(opts copySkillDirOptions) error {
	return filepath.WalkDir(opts.srcDir, func(srcPath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(opts.srcDir, srcPath)
		if err != nil {
			return err
		}
		if rel == "." {
			return os.MkdirAll(opts.dstDir, 0o755)
		}
		if entry.Type()&os.ModeSymlink != 0 {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		dstPath := filepath.Join(opts.dstDir, rel)
		if entry.IsDir() {
			return os.MkdirAll(dstPath, 0o755)
		}
		if entry.Type().IsRegular() {
			return copyRegularFile(copyRegularFileOptions{src: srcPath, dst: dstPath})
		}
		return nil
	})
}

type copyRegularFileOptions struct {
	src string
	dst string
}

func copyRegularFile(opts copyRegularFileOptions) error {
	info, err := os.Stat(opts.src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(opts.dst), 0o755); err != nil {
		return err
	}

	in, err := os.Open(opts.src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(opts.dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}
