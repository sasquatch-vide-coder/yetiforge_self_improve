# OpenClaw Feature Analysis for Rumpbot

Features from [OpenClaw](https://github.com/open-claw/open-claw) (167k stars, multi-platform AI assistant) that could improve rumpbot/tiffbot. Organized by priority for a single-user Telegram bot.

---

## High Priority — High Impact, Reasonable Effort

### 1. Persistent Memory System

**What it is:** A multi-layer memory system that gives the bot long-term recall across sessions. Daily conversation logs, a persistent `MEMORY.md` summary file, and semantic search over past conversations.

**How OpenClaw does it:** Three tiers — short-term (current context window), medium-term (daily log files auto-summarized), and long-term (vector-indexed summaries searchable by relevance). The bot auto-updates its memory file at session boundaries and can be asked "what did we discuss last week about X."

**Why it matters for rumpbot:** Currently rumpbot loses all context between Claude invocations unless `--resume` works. If a session expires or resets, everything is gone. A memory layer would let Tiffany remember user preferences, past decisions, project context, and ongoing threads without relying on Claude's session resume.

**Complexity:** Medium. Core implementation is file-based (daily logs + summary file). Semantic search adds complexity (needs embeddings + vector store) but a simpler keyword/recency approach works for single-user. Start with auto-appending conversation summaries to a memory file, injected as system context.

---

### 2. Context Management Commands

**What it is:** User-facing commands to inspect and manage the context window — how full it is, what's in it, and the ability to compact/summarize it.

**How OpenClaw does it:** `/compact` summarizes the current conversation into a shorter form and resets context. `/context` shows token usage breakdown (system prompt, conversation history, tool results). Users can see when they're approaching limits and proactively manage it.

**Why it matters for rumpbot:** Claude CLI has context limits. When conversations get long, responses degrade or fail. Users currently have no visibility into this — they just notice things getting weird. A `/compact` command could summarize and restart the session, while `/context` gives transparency.

**Complexity:** Low-Medium. Token counting requires tiktoken or Claude's own reporting. `/compact` is essentially "summarize conversation, reset session, inject summary as context." The plumbing for session reset already exists via `/reset`.

---

### 3. Message Queueing & Debouncing

**What it is:** Smart handling of rapid-fire messages. Instead of dropping or processing each independently, coalesce multiple quick messages into a single prompt.

**How OpenClaw does it:** Configurable debounce window (default ~1.5s). When a user sends multiple messages in quick succession, they're collected and sent as one combined prompt. Also supports a queue for when the bot is busy — messages wait instead of being dropped.

**Why it matters for rumpbot:** Currently `ChatLocks` prevents concurrent Claude invocations per chat, but messages arriving while Claude is processing are effectively dropped (user gets a "busy" message). Queueing would let those messages wait and be processed next. Debouncing would catch the common "send, realize you forgot something, send again" pattern.

**Complexity:** Low-Medium. Debouncing is a timer + message buffer. Queueing requires a per-chat message queue that processes after the current invocation completes. Both are straightforward data structure work on top of existing ChatLocks.

---

### 4. Dynamic Model Switching

**What it is:** A `/model` command that lets the user switch which Claude model is used mid-conversation.

**How OpenClaw does it:** `/model` shows available models, `/model gpt-4o` switches. Per-chat model preference persisted. Some implementations also support per-message model override with a prefix.

**Why it matters for rumpbot:** Rumpbot has a three-tier agent system with admin-configurable model assignments, but users can't switch models at runtime. Sometimes you want Haiku for quick answers and Opus for complex reasoning. A `/model` command would let the user pick without redeploying.

**Complexity:** Low. The invoker already accepts model parameters. Add a per-chat model preference (stored in session data), a `/model` command to set it, and pass it through to the Claude CLI invocation. The agent tier system can provide defaults while allowing runtime override.

---

### 5. Streaming Responses

**What it is:** Instead of waiting for the full Claude response before sending anything, send completed blocks (paragraphs, code blocks) as they're ready.

**How OpenClaw does it:** Block streaming — buffers output and sends complete paragraphs/sections as individual Telegram messages. Uses Telegram's `editMessageText` to update a "thinking..." message with content as it arrives, or sends sequential messages for long responses.

**Why it matters for rumpbot:** Claude invocations can take 30-60+ seconds. Users stare at a typing indicator with no feedback. Streaming would make the bot feel dramatically more responsive. Even a simple "edit message with partial content" approach would be a major UX improvement.

**Complexity:** Medium. Claude CLI with `--output-format stream-json` emits streaming events. The challenge is parsing partial output, deciding when a "block" is complete enough to send, and handling Telegram's rate limits on message edits (~30/minute). Start with periodic message updates (every 5-10s) rather than true per-token streaming.

---

### 6. Usage/Cost Commands

**What it is:** User-facing command showing token usage, cost estimates, and history.

**How OpenClaw does it:** `/usage` shows daily/weekly/monthly token counts and estimated costs. Some implementations include per-conversation breakdowns and budget alerts.

**Why it matters for rumpbot:** Rumpbot already logs invocations with cost data to SQLite. The dashboard shows this, but the user has to leave Telegram to check. A `/usage` command would surface this data inline — "today: $2.34 across 15 invocations, this month: $47.80."

**Complexity:** Low. The data already exists in the invocations database. Just needs a command handler that queries SQLite and formats the results. Could also add budget warnings ("you've spent $X today, heads up").

---

## Medium Priority — Good Features, More Effort

### 7. Group Chat Support

**What it is:** Bot functionality in group chats with configurable policies — mention-gating, per-group sessions, admin controls.

**How OpenClaw does it:** Configurable per-group: require @mention or reply to activate, separate conversation contexts per group, group admin can set policies (who can use the bot, rate limits, allowed commands). Handles the complexity of multiple users in one chat.

**Why it matters for rumpbot:** Currently DM-only. Group support would let multiple people interact with Tiffany in a shared context — useful for team discussions, shared projects, or just having the bot in a friend group.

**Complexity:** Medium-High. grammY supports groups natively, but the session/context model needs rethinking. Need per-group sessions (not per-user), mention detection, and policies for who can trigger the bot. The auth system needs group-level rules alongside user-level.

---

### 8. Scheduled Tasks / Cron

**What it is:** Ability to schedule recurring prompts — daily summaries, periodic checks, reminders.

**How OpenClaw does it:** Built-in cron-like scheduler. Users set up tasks like "every morning at 9am, summarize my GitHub notifications" or "every Friday, review this week's commits." Tasks run as regular Claude invocations with results sent to the user.

**Why it matters for rumpbot:** Turns the bot from reactive (waits for messages) to proactive (can initiate). Useful for: daily standup prompts, periodic code review reminders, scheduled status checks, or even "remind me to deploy on Friday."

**Complexity:** Medium. node-cron or similar for scheduling. Each task is essentially a programmatic Claude invocation with a preset prompt. Needs persistence (survive restarts), a `/schedule` command for management, and error handling for failed scheduled runs.

---

### 9. Skills/Plugin System

**What it is:** Modular, loadable capability packages. Each skill is a folder with metadata, prompt templates, and optional tool definitions.

**How OpenClaw does it:** Skills directory with auto-discovery. Each skill has a `manifest.json` (name, description, triggers, required tools) and prompt templates. Skills can be enabled/disabled per chat. The system injects relevant skill prompts based on user intent.

**Why it matters for rumpbot:** Currently all capabilities are hardcoded. A plugin system would let you add new features (code review skill, deployment skill, writing skill) without modifying core bot code. Could also let Tiffany's personality be a "skill" that's composable with others.

**Complexity:** Medium-High. Need a plugin loader, manifest format, lifecycle hooks (init, cleanup), and a way to inject skill context into Claude prompts. The three-tier agent system could map to skill-specific agent configurations.

---

### 10. Web Search Integration

**What it is:** Built-in ability to search the web and incorporate results into responses.

**How OpenClaw does it:** Brave Search API (or Google/Bing) integration as a tool. When the user asks about current events or needs up-to-date info, the bot searches and includes results in the Claude prompt as context.

**Why it matters for rumpbot:** Claude has a knowledge cutoff. Web search would let Tiffany answer questions about current events, look up documentation, check package versions, etc. Particularly useful for a coding assistant that needs current API docs.

**Complexity:** Low-Medium. Brave Search API is simple (API key + HTTP request). The main work is deciding when to search (explicit command vs. auto-detect) and how to format results for Claude's context. Could start with a `/search` command and later add auto-detection.

---

### 11. Browser Automation

**What it is:** Playwright-based web browsing — visit pages, take screenshots, extract content, interact with forms.

**How OpenClaw does it:** Playwright instance managed by the bot. Can navigate to URLs, screenshot pages, extract text content, fill forms, click buttons. Results (screenshots, extracted text) are sent back to the user or fed into Claude for analysis.

**Why it matters for rumpbot:** Enables capabilities like: "go to this URL and tell me what you see," screenshot-based debugging ("here's what the page looks like"), form testing, and scraping. Powerful for a development-focused bot.

**Complexity:** High. Playwright is heavyweight (headless Chromium). Needs careful resource management on a VPS, security sandboxing (don't let it visit arbitrary sites without limits), and screenshot-to-Telegram pipeline. Memory usage is a concern on the Oracle Cloud free tier.

---

### 12. Webhook Triggers

**What it is:** HTTP endpoints that trigger bot actions from external services — GitHub webhooks, CI/CD notifications, monitoring alerts.

**How OpenClaw does it:** Configurable webhook receiver. Each webhook maps to a handler that processes the payload and optionally invokes Claude or sends a notification. Supports GitHub, GitLab, JIRA, and custom webhooks.

**Why it matters for rumpbot:** Rumpbot already has a Fastify server. Adding webhook endpoints would let it react to: GitHub push/PR events, deployment status changes, monitoring alerts, or any external service. "Your deploy failed" → Tiffany tells you in Telegram with analysis.

**Complexity:** Medium. Fastify routes for webhook ingestion, payload validation (webhook signatures), and mapping to bot actions. The hardest part is designing a flexible handler system that doesn't require code changes for each new webhook source.

---

## Lower Priority — Nice-to-Have, Large Effort or Niche

### 13. Multi-Channel Support

**What it is:** Support for Discord, Slack, WhatsApp, and other messaging platforms alongside Telegram.

**How OpenClaw does it:** Channel abstraction layer. Each platform has an adapter that normalizes messages into a common format. Core logic is channel-agnostic. OpenClaw supports 20+ channels through this abstraction.

**Why it matters for rumpbot:** Currently Telegram-only. Multi-channel would be useful if you want the same bot in Discord or Slack. However, for a personal bot, this is low priority — Telegram is the primary interface.

**Complexity:** High. Requires abstracting all Telegram-specific code behind a channel interface. Each new platform needs its own adapter, message format handling, and platform-specific features (reactions, threads, etc.). Major architectural change.

---

### 14. Voice/TTS Support

**What it is:** Voice message input (speech-to-text) and voice response output (text-to-speech).

**How OpenClaw does it:** Whisper API for STT, ElevenLabs or OpenAI TTS for speech synthesis. Voice messages are transcribed, processed, and optionally responded to with audio.

**Why it matters for rumpbot:** Convenience feature — talk to Tiffany instead of typing. The personality would be especially fun with a matching voice. Telegram natively supports voice messages, so the UX is smooth.

**Complexity:** Medium. STT is straightforward (Whisper API). TTS requires choosing a service, generating audio, and sending as Telegram voice message. Latency is a concern — STT + Claude + TTS adds up. Cost of TTS APIs for a personal bot is also a factor.

---

### 15. Device Nodes

**What it is:** Remote device control — execute commands on connected machines, manage services, deploy code.

**How OpenClaw does it:** Agent nodes on remote devices that connect back to the hub. The bot can dispatch commands to specific devices, collect results, and manage fleets of machines.

**Why it matters for rumpbot:** Could control the VPS or other machines from Telegram. "Restart the nginx service" or "check disk usage on the server." However, rumpbot already has Claude CLI which can run commands — this is more about multi-machine orchestration.

**Complexity:** High. Requires a node agent, secure communication channel, authentication, and command sandboxing. Security is critical — remote code execution from a Telegram bot needs careful access control.

---

### 16. Doctor/Diagnostics Command

**What it is:** Self-diagnostic tool that checks configuration, connectivity, dependencies, and reports issues.

**How OpenClaw does it:** `/doctor` command that checks: API keys valid, services reachable, disk space adequate, dependencies installed, configuration complete. Reports issues with suggested fixes.

**Why it matters for rumpbot:** Useful for debugging deployment issues. "Why isn't the bot working?" → `/doctor` tells you the Claude CLI isn't authenticated, or the API key expired, or disk is full.

**Complexity:** Low. Series of health checks (file exists, service responds, CLI works) formatted as a report. The `/status` command already does some of this — could be extended.

---

### 17. Onboarding Wizard

**What it is:** Guided first-time setup instead of manual `.env` file editing.

**How OpenClaw does it:** Interactive CLI wizard on first run. Prompts for API keys, configures services, tests connections, and writes config files. Web-based setup UI as alternative.

**Why it matters for rumpbot:** Currently setup requires manually creating `.env` with correct values. A wizard would be friendlier, but for a personal project with one deployment, it's low priority.

**Complexity:** Low-Medium. Interactive prompts (inquirer.js or similar), config validation, and file writing. Nice polish but not essential for a single-user bot.

---

### 18. Docker Sandbox

**What it is:** Isolated execution environments for running untrusted code safely.

**How OpenClaw does it:** Docker containers spun up per execution. Code runs in a sandboxed environment with resource limits, network restrictions, and auto-cleanup. Prevents malicious or buggy code from affecting the host.

**Why it matters for rumpbot:** Claude CLI can already execute code on the VPS. Docker sandboxing would add safety — if Claude generates and runs bad code, it can't damage the host system. Important for a bot that runs on a production server.

**Complexity:** High. Docker setup, container management, resource limits, cleanup, and integration with Claude CLI's execution. The Oracle Cloud free tier may not have enough resources for comfortable Docker usage.

---

### 19. Extension/Plugin Registry

**What it is:** Marketplace for discovering and installing community plugins.

**How OpenClaw does it:** Central registry (npm-like) where users publish and discover plugins. CLI commands to search, install, and manage plugins.

**Why it matters for rumpbot:** Only relevant if the plugin system (feature #9) exists and the project has a community. For a personal bot, this is very low priority.

**Complexity:** High. Requires the plugin system first, then a registry service, publishing workflow, versioning, and security review process. Overkill for a personal project.

---

## Implementation Notes

- Features are ordered by impact-to-effort ratio within each tier
- All features are described as concepts/patterns — no code was copied from OpenClaw
- Many high-priority features build on existing rumpbot infrastructure (SQLite logging, Fastify server, session management)
- Recommended first picks: **Persistent Memory** (#1) and **Message Queueing** (#3) would have the most immediate impact on daily usage
- **Streaming Responses** (#5) would have the biggest perceived UX improvement
- **Usage Commands** (#6) is the lowest-effort high-value feature since the data already exists
