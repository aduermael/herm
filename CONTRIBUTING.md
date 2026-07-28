# Contributing to herm

Thanks for contributing. herm is a coding agent CLI: containerized by default
(Docker), with optional CPSL local sandbox and naked host modes. This guide
covers setup, PR expectations, and coding standards for Go CLI changes. For
native CPSL builds see [`CPSL_BUILD.md`](CPSL_BUILD.md); for architecture
overview see [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Prerequisites

- Go **1.24+**
- Git (with submodule support)
- Docker (for the default container backend and many integration scenarios)
- Optional: Rust and native toolchains if you work on CPSL builds

## Setup

```sh
git clone https://github.com/aduermael/herm
cd herm
git submodule update --init external/langdag external/cpsl
go build -o herm ./cmd/herm
```

If you cloned without submodules, run the `git submodule update --init` line
before building.

`external/langdag` and `external/cpsl` are separate projects. Prefer changes in
this repo unless the work truly belongs upstream; when editing a submodule,
follow that project's own contributing docs and keep submodule pointer updates
explicit in the PR.

## Develop and test

Build and run the CLI from the repo root:

```sh
go build -o herm ./cmd/herm
./herm
```

Run the full Go test suite:

```sh
go test ./...
```

Structural CI rules (file length, positional params, file doc comments) live in
`tools/ci-check/`. Run them the same way CI does:

```sh
go run ./tools/ci-check all .
```

## Pull requests

- Keep PRs focused: one concern per change when practical.
- Match existing style and package layout under `cmd/herm/`.
- When behavior changes, add or update tests (`go test`) that exercise the real
  path under test.
- Run `go test ./...` and `go run ./tools/ci-check all .` before opening or
  updating a PR.
- Do not commit local planning docs or a `plans/` tree — see
  [What not to commit](#what-not-to-commit).
- Do not commit credentials, `.env` files, or ignored build caches.

## Coding standards

### CI-enforced rules

Three structural rules are enforced by `tools/ci-check/` and run on every PR:

1. **File length** — non-test `.go` files are capped at 1000 lines. Split if larger.
2. **Positional params** — functions/methods take at most 1 positional parameter.
   When more data is needed, use an options struct (`type FooOptions struct {...}`,
   `func Foo(opts FooOptions)`). A leading `ctx context.Context` is exempt from
   the count, and a trailing variadic parameter is allowed alongside one regular
   param. Receivers and interface method declarations are not checked.
3. **File docstring** — every non-test `.go` file starts with a leading doc
   comment whose body is ≥ 60 chars and ≤ 3 lines.

Run `go run ./tools/ci-check all .` from the repo root to check locally.

### File size

- Source files: 1000 lines max. If a file grows past this, split it.
- Test files: flexible — large test files that mirror source structure are fine.

### Package-level doc comments

Every non-test `.go` file must have a doc comment before the `package` declaration
explaining the file's purpose:

```go
// render.go contains terminal rendering and display functions for the TUI,
// including message formatting, code block layout, and cursor positioning.
package main
```

Keep it to 1–3 lines (≥ 60 chars). Describe what the file is responsible for, not
implementation details.

### Naming

- Unexported identifiers: `camelCase` — `promptPrefix`, `maxAttachmentBytes`
- Exported identifiers: `PascalCase` — `NewBashTool`, `AgentEvent`
- Receiver names: short, lowercase — `(a *App)`, `(t *BashTool)`, `(c *ContainerClient)`
- Loop/temp variables: single letters or short abbreviations — `i`, `n`, `cfg`, `cmd`
- Constants: follow the same exported/unexported convention — `ProviderAnthropic`, `modeChat`
- Enum-like constants: use `iota`

### Imports

Three groups separated by blank lines, each sorted alphabetically:

1. Standard library
2. Third-party packages
3. Local packages (`langdag.com/...`)

### Error handling

- Always check and return errors explicitly.
- Wrap with context using `%w`: `fmt.Errorf("load config: %w", err)`
- Use `%v` or `%s` when the caller should not unwrap: `fmt.Errorf("container %s: %s", code, msg)`
- Error messages describe the operation that failed, lowercase, no trailing punctuation.
- Return early on error — avoid deep nesting.

### Comments

- Doc comments start with the identifier name: `// Definition returns the tool definition.`
- Use full sentences ending with a period.
- Inline comments explain *why*, not *what*.
- Section headers use the decorative style: `// ─── Constants ───`

### Tests

- Table-driven tests with `t.Run` for multiple cases:
  ```go
  tests := []struct {
      name string
      in   string
      want string
  }{...}
  for _, tt := range tests {
      t.Run(tt.name, func(t *testing.T) { ... })
  }
  ```
- Use `t.Helper()` in test helpers.
- Use `t.TempDir()`, `t.Setenv()`, `t.Cleanup()` instead of manual setup/teardown.
- Use `t.Fatalf` for setup failures, `t.Errorf` for assertion failures.
- No external assertion libraries — use explicit `if got != want` checks.

### File organization

Typical file structure, top to bottom:

1. Package doc comment
2. `package main`
3. Imports
4. Constants (grouped with section headers if many)
5. Type definitions
6. Constructor functions
7. Methods
8. Helper functions

## What not to commit

Keep local working artifacts out of the repository:

- **Plans and planning docs** — do not commit project plan files, design
  scratchpads, or a `plans/` tree (or equivalent local planning directories).
  Planning is fine on disk for your own workflow; it does not belong in git
  history for this repo.
- Other local-only paths (credentials, build caches, IDE noise) stay in
  `.gitignore` as usual; do not force-add them.

## Docs map

| Doc | Use |
|-----|-----|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | System design |
| [`CLI_QUICK_START.md`](CLI_QUICK_START.md) / [`COMMANDS_REFERENCE.md`](COMMANDS_REFERENCE.md) | CLI usage |
| [`CPSL_BUILD.md`](CPSL_BUILD.md) | Native CPSL sandbox build |
| [`ENTRY_POINTS.md`](ENTRY_POINTS.md) | Entry points and wiring |

If this file grows large, prefer nested docs under `docs/` linked from here
rather than new top-level markdown files.

## Community

Questions and discussion: [Discord](https://discord.gg/WFjcymwtZU).

## License

By contributing, you agree that your contributions are licensed under the
project [MIT](LICENSE) license.
