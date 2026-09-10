# Agent Instructions

## Code exploration toolset

When available, use CodeGraph and Serena before falling back to broad text searches or whole-file reads.

- **CodeGraph**: When `.codegraph/` exists at the repository root, use `codegraph explore "<question or symbol>"` or the equivalent CodeGraph MCP tool first for source-code questions. It provides symbol-aware source and call paths.
- **Serena**: Activate the current project and read its initial instructions before coding. Prefer Serena's symbol overview, symbol lookup, reference, and implementation tools for targeted source exploration; use pattern search for non-code files or when a symbol is not known.
- **Fallback**: If either tool is unavailable or cannot answer the question, use `rg` and targeted file reads.

## Agent skills

### Issue tracker

Issues live in this repository's GitHub Issues, operated with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository using root `CONTEXT.md` and `docs/adr/`. See `docs/agents/domain.md`.
