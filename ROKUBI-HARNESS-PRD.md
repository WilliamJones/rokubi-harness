# ROKUBI Harness
## Product Requirements Document

**Version:** 0.4  
**Status:** Draft  
**Product Type:** Desktop AI Development Environment  
**Primary Platform:** macOS, Windows, Linux  
**Primary AI Provider:** OpenAI  

---

# 1. One-Line Description

> **ROKUBI Harness is a simple visual harness for autonomous software development—give ChatGPT a goal, watch it work, inspect the evidence, and intervene only when you need to.**

---

# 3. Brand Architecture

**ROKUBI** is the parent company and product brand.

**ROKUBI Harness** is the autonomous software-development harness product.

Recommended public naming:

```text
ROKUBI
└── ROKUBI Harness
```

Recommended initial web presence:

```text
rokubi.com/harness
```

Use **ROKUBI Harness** on first mention. In product UI, **Harness** may be used when the surrounding context is unambiguous.

---

# 4. Product Vision

ROKUBI Harness is an AI-first development environment combining:

- the autonomous software-engineering workflow of Claude Code,
- the visual file editing and project navigation strengths of VS Code,
- and the simplicity philosophy of Pi.

The product is intentionally **not** a complete IDE.

It should provide:

> **Everything required for serious AI-assisted software development, but nothing before it becomes necessary.**

The default experience is simply:

**Project + Editor + ChatGPT**

More advanced surfaces appear only when the current task requires them.

The editor exists as a visual control surface for the agent—not as the product's primary identity.

---

# 4. Differentiation Pillars

The product should be differentiated by the discipline of the overall experience rather than by a checklist of isolated AI coding features.

## 3.1 Necessary Complexity

The interface reveals complexity only when the current task demands it.

The default experience remains:

```text
Project | Editor | ChatGPT
```

Additional capabilities such as terminal output, plans, diagnostics, diffs, Git actions, tests, and verification results appear contextually and recede when no longer useful.

The product should be as simple as possible **for the task currently being performed**.

A capability must earn permanent interface space through frequency and necessity.

---

## 3.2 Conversational Agency

The user should not be forced to select artificial Ask, Plan, Edit, or Agent workflows before interacting with ChatGPT.

Intent should come naturally from the conversation.

Examples:

> Explain how authentication works.

The agent reads and explains.

> Plan how we should migrate this to OAuth.

The agent investigates and creates a plan.

> Do it.

The agent edits.

> Fix the tests and keep going until everything passes.

The agent executes, diagnoses, fixes, and verifies.

The primary control should be **authority**, not behavioral mode.

Example:

```text
Autonomy: Standard ▾
```

Suggested presets:

- Read Only
- Standard
- Ask Before Commands
- Full Autonomy

---

## 3.3 Verified Autonomy

Autonomous work should end with evidence, not merely an AI statement that the task is complete.

Every meaningful completion should answer:

1. **What changed?**
2. **What was verified?**
3. **Can I inspect or undo it?**

Example:

```text
TASK COMPLETE

Authentication implemented.

Changes
4 files modified
1 file created

Verified
✓ TypeScript
✓ Lint
✓ 48/48 tests
✓ Production build

[Review Changes]  [Commit]  [Undo Task]
```

The product should favor visible outcomes and evidence over verbose AI narration.

Agent activity should be concise and expandable:

```text
✓ Searched project
✓ Read 6 relevant files
✓ Changed 4 files
✓ npm test — 48 passed
✓ npm run build — successful
```

This creates a trust-oriented UX for autonomous development.

---

## 3.4 Capability Without UI Bloat

The agent may have many capabilities without the interface exposing a permanent panel, menu, or settings screen for each one.

Capabilities should scale through:

```text
Primitives
   ↓
Tools
   ↓
Skills
   ↓
Commands
   ↓
Contextual UI
   ↓
Permanent UI only when justified
```

The harness should resist feature accumulation.

A new capability should not automatically create new visible UI.

The guiding question is:

> Does the agent need this capability?

followed separately by:

> Does the human need this permanently visible?

Those answers may be different.

---

# 5. Core Design Principle: Necessary Complexity

The application should not optimize for maximum minimalism or maximum functionality.

It should optimize for **Necessary Complexity**.

The product should prefer:

- primitives over features,
- files over proprietary subsystems,
- conversational intent over modes,
- contextual UI over permanent panels,
- skills over built-in workflows,
- progressive disclosure over settings screens,
- lightweight configuration over complex administration.

The harness should feel simple when the task is simple and become more powerful only as the task becomes more complex.

---

# 6. Problem

AI coding products typically fall into two categories.

## Terminal-first agents

Tools such as Claude Code provide strong autonomous capabilities:

- repository inspection
- project search
- multi-file editing
- terminal execution
- testing
- debugging
- Git operations
- planning
- iterative verification

But they provide limited visual project navigation and code-review workflows.

## IDE-first assistants

Traditional IDEs provide excellent:

- file navigation
- code editing
- diagnostics
- terminal integration
- source control
- debugging

But AI is often treated as an additional sidebar rather than the primary software-engineering interface.

ROKUBI Harness should unify both models without inheriting the full complexity of either.

---

# 7. Product Principles

## 6.1 Agent First

ChatGPT is the primary interaction layer.

The editor supports the agent rather than the agent being added to the editor.

The conceptual hierarchy should be:

```text
AGENT
 ├── project
 ├── editor
 ├── terminal
 ├── tests
 ├── Git
 └── tools
```

rather than:

```text
EDITOR
 ├── terminal
 ├── Git
 ├── debugger
 └── AI
```

---

## 6.2 Progressive Complexity

The default workspace should contain only:

- Project Files
- Code Editor
- ChatGPT

Other surfaces appear contextually.

---

## 6.3 Primitives Over Features

The core agent should primarily operate through a small number of primitives:

```text
READ
SEARCH
EDIT
CREATE
DELETE
RUN
```

Higher-level capabilities should compose these primitives rather than become separate systems.

---

## 6.4 Everything Is Observable

Users should be able to understand what the agent is doing without seeing hidden reasoning.

Visible activity may include:

- files read
- searches performed
- files edited
- commands executed
- tests run
- errors encountered
- verification performed

Agent activity should normally remain collapsed unless expanded.

---

## 6.5 Everything Is Reversible

AI modifications should be checkpointed.

Users should be able to:

- undo individual edits
- revert a file
- undo an agent task
- restore a checkpoint

Checkpoints should work independently of Git.

---

## 6.6 Humans Can Intervene Anytime

Manual edits immediately become part of the live project state.

The agent should detect changed files before continuing work.

---

## 6.7 Files Before Subsystems

Before adding a new product subsystem, ask:

> Can a normal project file already solve this adequately?

Examples:

| Need | Default Representation |
|---|---|
| Project instructions | `AGENTS.md` |
| Architecture notes | `ARCHITECTURE.md` |
| Task plan | Markdown checklist |
| Custom workflow | Skill file |
| Prompt template | Markdown file |
| Project knowledge | Files + search |

Frequently used behaviors may later graduate into dedicated UI.

---

## 6.8 Capabilities Must Earn Permanent UI

A capability should evolve through:

```text
LLM Behavior
     ↓
Skill
     ↓
Command
     ↓
Contextual UI
     ↓
Permanent UI
```

Only highly frequent capabilities should reach the final stage.

---

# 8. Target Users

Primary users:

- AI-first developers
- indie hackers
- SaaS builders
- technical founders
- software engineers
- QA automation engineers
- technical business analysts

Secondary users:

- students
- DevOps engineers
- data engineers
- product builders comfortable working with source code

---

# 9. Primary Jobs To Be Done

Users should be able to say:

- "Implement the authentication flow in PRD.md."
- "Explain how this project works."
- "Fix the failing tests."
- "Create this feature."
- "Refactor this module."
- "Upgrade this package."
- "Review my changes."
- "Find every place this API is used."
- "Run the app and fix whatever breaks."
- "Show me what you changed."
- "Undo that."

The harness should execute the necessary development workflow instead of merely returning code snippets.

---

# 10. Default Application Layout

The initial UI should be intentionally sparse.

```text
┌───────────────────────────────────────────────────────────┐
│ project-name                         GPT-5.6       •••    │
├──────────────┬──────────────────────────────┬─────────────┤
│              │                              │             │
│   Files      │           Editor             │   ChatGPT   │
│              │                              │             │
│              │                              │             │
│              │                              │             │
│              │                              │             │
└──────────────┴──────────────────────────────┴─────────────┘
```

The user should understand the application within seconds.

---

# 11. Contextual UI

Additional surfaces appear only when relevant.

## Terminal

Appears when the user or agent runs a command.

```text
──────────── Terminal ────────────
$ npm test
...
```

## Problems

Appears when diagnostics or failures exist.

```text
⚠ 2 Problems
```

## Changes

Appears after the agent modifies files.

```text
4 files changed    Review
```

## Plan

Appears only for tasks that benefit from planning.

```text
▾ Implementation Plan

✓ Inspect authentication flow
✓ Identify affected files
● Update middleware
○ Add tests
○ Verify build
```

## Agent Activity

Displayed inline in ChatGPT rather than occupying a permanent panel.

```text
ChatGPT

I'll update the authentication flow.

⌄ Searched project
⌄ Read 5 files
● Editing src/auth/session.ts
⌄ Ran npm test
  ✓ 48 tests passed
```

---

# 12. Conversational Intent Instead of Agent Modes

The application should not require the user to choose between Ask, Plan, Edit, and Auto before every task.

Intent should normally come from natural language.

The only persistent concept should be how much authority the user grants the agent.

---

# 13. Autonomy Control

Provide one compact control:

```text
Autonomy: Standard ▾
```

Suggested presets:

### Read Only
Can inspect but cannot modify.

### Standard
Can read, search, and edit. Potentially destructive or external actions require approval.

### Ask Before Commands
File edits may proceed, but terminal execution requires approval.

### Full Autonomy
Can continue through edit → run → test → fix → verify while still honoring hard security boundaries.

---

# 14. Core Functional Requirements

## FR-001 — Workspace

Users can:

- open a local folder
- open a Git repository
- create a project
- reopen recent projects
- switch projects

## FR-002 — File Explorer

Required:

- hierarchical folders
- create
- rename
- move
- delete
- duplicate
- drag/drop
- contextual actions

Agent edits update the Explorer immediately.

## FR-003 — Code Editor

Use Monaco or an equivalent editor.

Required:

- syntax highlighting
- line numbers
- tabs
- split editing
- find/replace
- code folding
- autocomplete
- formatting
- bracket matching
- multiple cursors
- keyboard shortcuts

## FR-004 — ChatGPT Workspace Conversation

ChatGPT conversations belong to the current project.

Users can reference:

```text
@src/auth.ts
@components
@selection
@terminal
@problems
@changes
```

## FR-005 — Context Engine

Always-loaded context should remain intentionally small.

### Always Available

- current objective
- system behavior
- `AGENTS.md`
- current file
- selected code
- small project map

### Retrieved On Demand

- related files
- dependencies
- Git history
- terminal output
- tests
- documentation
- previous decisions
- skills

The agent should search before loading large amounts of project context.

## FR-006 — Project Instructions

Support:

```text
AGENTS.md
```

Potential contents:

- architecture
- conventions
- preferred libraries
- forbidden patterns
- commands
- tests
- terminology
- deployment notes

## FR-007 — Agent Tools

### Filesystem

- read
- write
- patch
- create
- delete
- rename
- list

### Search

- filenames
- glob
- text
- regex
- symbols
- references

### Execution

- run command
- monitor process
- stop process

### Development

- build
- lint
- format
- test
- inspect diagnostics

### Git

- status
- diff
- log
- stage
- commit
- branch

All agent operations must be mediated by structured tools.

---

# 15. Integrated Terminal

The terminal should be hidden until used.

Required:

- multiple sessions
- Bash/Zsh/PowerShell support
- project-relative working directory
- clickable paths
- command history
- agent-readable output

Commands initiated by ChatGPT should be visually distinguishable from commands entered by the user.

---

# 16. Visual Diff Review

Agent changes should be reviewable without requiring a permanent Source Control panel.

After edits:

```text
4 files changed     Review
```

Selecting Review opens a focused diff experience.

Users can:

- accept all
- reject all
- accept file
- reject file
- accept individual change
- manually modify resulting code
- revert to checkpoint

---

# 17. Checkpoints

Create checkpoints automatically before significant agent edits.

Support:

- revert file
- undo latest agent action
- restore task start
- compare checkpoint

Checkpoints remain independent of Git.

---

# 18. Permissions

Permissions can exist at:

- global level
- project level
- session level

Example:

```text
ALLOW
read files
search files
git status
npm test

ASK
install packages
delete files
git commit
network access

DENY
force push
unsafe filesystem operations
```

Permission prompts should appear only when needed.

---

# 19. Planning

Planning should be a contextual artifact, not a permanent subsystem.

For complex tasks, ChatGPT can generate:

```text
Implementation Plan

✓ Locate authentication flow
✓ Inspect current tests
● Modify middleware
○ Add coverage
○ Run full verification
```

For simple tasks, no plan should appear.

---

# 20. Verification Loop

For implementation tasks, the agent should normally attempt:

```text
EDIT
 ↓
BUILD / LINT
 ↓
TEST
 ↓
INSPECT FAILURE
 ↓
FIX
 ↓
RETEST
 ↓
VERIFY
```

Completion reports should distinguish between:

- implemented
- compiled
- linted
- tested
- manually inspected
- not verified

---

# 21. Skills

Skills should be the primary way to add higher-level workflows.

Examples:

```text
/review
/security-review
/test
/refactor
/create-prd
/deploy
/browser-test
```

Skills may combine:

- prompts
- instructions
- tools
- commands
- validation rules

Skills should be discoverable but should not clutter the default interface.

---

# 22. Extension Architecture

The MVP does not require an extension marketplace.

However, the architecture should support:

```text
Harness Core
   │
   ├── Tools API
   ├── Skills API
   ├── Commands API
   ├── Events API
   └── UI Extension API
```

The core product should remain small even as the ecosystem grows.

---

# 23. Git

Git should be a core capability but not necessarily a permanent sidebar.

MVP:

- status
- diff
- stage
- unstage
- commit
- branch
- history

Git UI can surface contextually when changes exist.

---

# 24. Diagnostics

Compiler, type, lint, and test errors should surface only when relevant.

Example:

```text
⚠ 3 Problems
```

Selecting a problem should open its location.

Provide:

```text
Fix with ChatGPT
```

---

# 25. Command Palette

A command palette should act as the universal escape hatch for capabilities that do not deserve permanent UI.

Examples:

```text
Open Project
Review Changes
Run Tests
Format File
Git Commit
Open Terminal
Change Model
Manage Skills
Restore Checkpoint
```

Suggested keyboard shortcut:

```text
⌘K / Ctrl+K
```

---

# 26. Suggested Technical Architecture

## Desktop Shell

Preferred:

**Tauri + React + TypeScript**

Alternative:

**Electron + React + TypeScript**

## Editor

**Monaco Editor**

## Local Agent Service

Responsible for:

- model communication
- context assembly
- filesystem operations
- search
- terminal execution
- Git
- process management
- permissions
- checkpoints
- usage accounting

## AI Layer

Use an OpenAI model adapter.

Interface:

```text
send()
stream()
toolCall()
resume()
cancel()
usage()
```

The UI should not depend directly on one specific model.

---

# 27. Security Model

```text
OpenAI Model
      │
      ▼
Agent Orchestrator
      │
      ▼
Permission Engine
      │
      ▼
Structured Tools
      │
      ▼
Local Machine
```

The model never receives unrestricted operating-system access.

Support exclusions such as:

```text
.env
*.pem
*.key
credentials.json
```

---

# 28. MVP Scope

## Always Visible

- project files
- code editor
- ChatGPT

## Contextually Visible

- terminal
- plan
- changes
- diagnostics
- Git actions
- agent activity
- verification results

## Core Capabilities

- read/search/edit files
- run commands
- visual diffs
- checkpoints
- permissions
- project context
- persistent conversations
- `AGENTS.md`
- testing
- Git awareness
- command palette

---

# 29. MVP Non-Goals

Do not initially build:

- complete VS Code extension compatibility
- extension marketplace
- full debugger UI
- remote SSH
- Dev Containers
- collaborative editing
- cloud agents
- notebook environment
- mobile application
- full GitHub PR management
- complex multi-agent dashboards
- permanent task-management UI
- large settings surface
- multi-provider model routing

---

# 30. Primary MVP Workflow

User opens a repository.

The UI initially shows only:

```text
Files | Editor | ChatGPT
```

User types:

> Add dark mode using the existing design system and make sure the tests pass.

ChatGPT:

1. searches the project
2. reads relevant files
3. creates a lightweight plan if needed
4. modifies code
5. exposes `4 files changed`
6. runs tests
7. sees a failure
8. fixes it
9. reruns tests
10. reports verification

The UI expands only as necessary:

```text
Files | Editor | ChatGPT
           +
       Plan
       Terminal
       Changes
       Problems
```

After completion, contextual surfaces can collapse again.

---

# 31. Completion Experience

Example:

```text
TASK COMPLETE

Dark mode implemented.

Changes
4 files changed

Verified
✓ TypeScript
✓ Lint
✓ 14 tests
✓ Build

[Review Changes]   [Commit]   [Undo Task]
```

---

# 32. Product Success Criteria

The MVP succeeds when a developer can:

1. open a repository
2. browse and edit files manually
3. ask ChatGPT to implement a feature
4. watch relevant agent actions
5. let ChatGPT modify multiple files
6. review visual diffs
7. run commands
8. diagnose failures
9. automatically iterate on fixes
10. verify success
11. undo the task
12. commit accepted work

without needing to understand a complex IDE interface.

---

# 33. Product Positioning

The harness should never become:

> "VS Code with another AI sidebar."

Nor should it become:

> "A terminal agent with an editor attached."

It should be:

> **A simple visual control surface for an autonomous software engineer powered by ChatGPT.**

The market position is intentionally between ultra-minimal terminal harnesses and full AI-native IDEs.

The product should aim for:

- Claude Code-level agency
- VS Code-level visibility
- Pi-level restraint

while developing its own identity around:

- Necessary Complexity
- Conversational Agency
- Verified Autonomy
- Capability Without UI Bloat

---

# 34. Final Product Principle

The default experience remains:

```text
PROJECT + EDITOR + CHATGPT
```

Everything else appears only when the user actually needs it.

The harness may become extremely capable.

The interface should not become proportionally complicated.

That is the product's definition of **Necessary Complexity**.
