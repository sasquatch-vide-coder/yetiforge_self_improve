import type { StreamEvent } from "../agents/types.js";

/** Always format as Xm Ys (even under 60s: "0m Xs"). */
function formatElapsed(ms: number): string {
  const totalSec = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSec / 60);
  const seconds = totalSec % 60;
  if (minutes < 60) return `${minutes}m ${seconds}s`;
  const hours = Math.floor(minutes / 60);
  const remainingMin = minutes % 60;
  return `${hours}h ${remainingMin}m`;
}

/** Format a token count as k/M for compact display. */
function formatTokenCount(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

export interface FinalSummaryData {
  costUsd: number;
  durationMs: number;
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  success: boolean;
}

/**
 * StreamFormatter accumulates structured events from the executor and renders
 * a minimal progress panel for Telegram.
 *
 * Layout:
 *   ⚙️ Working — Xm Ys
 *
 *   ✏️ N edits  📂 N reads  ▶️ N commands
 *
 *   💬 [latest status from Claude's text output]
 *
 * The header label is configurable (e.g. "Planning", "Iteration 2/5").
 * Everything else renders identically across all contexts.
 */
export class StreamFormatter {
  private editCount = 0;
  private readCount = 0;
  private commandCount = 0;
  private latestStatusText: string | null = null;
  private startTime: number;
  private headerLabel: string;
  private lastRendered = "";

  constructor(headerLabel: string = "\u2699\uFE0F Working") {
    this.startTime = Date.now();
    this.headerLabel = headerLabel;
  }

  /** Add a structured event — updates counts and status text. */
  addEvent(event: StreamEvent): void {
    switch (event.type) {
      case "file_read":
        this.readCount++;
        break;
      case "file_edit":
      case "file_write":
        this.editCount++;
        break;
      case "command":
        this.commandCount++;
        break;
      case "status_text":
        this.latestStatusText = event.detail;
        break;
    }
  }

  /** Get total event count (edits + reads + commands). */
  get eventCount(): number {
    return this.editCount + this.readCount + this.commandCount;
  }

  /** Render the formatted progress panel. Returns empty string if nothing changed. */
  render(forceRender = false): string {
    const rendered = this.buildPanel();
    if (!forceRender && rendered === this.lastRendered) {
      return "";
    }
    this.lastRendered = rendered;
    return rendered;
  }

  /** Always render regardless of changes. */
  renderForce(): string {
    this.lastRendered = this.buildPanel();
    return this.lastRendered;
  }

  /** Render a final summary panel (Done/Failed + counts + cost/tokens). */
  renderFinalSummary(data: FinalSummaryData): string {
    const elapsed = formatElapsed(data.durationMs);
    const icon = data.success ? "\u2705" : "\u274C";
    const label = data.success ? "Done" : "Failed";

    const lines: string[] = [];
    lines.push(`${icon} ${label} \u2014 ${elapsed}`);
    lines.push("");

    // Counts line
    lines.push(this.buildCountsLine());

    // Cost + tokens line
    const costStr = `\u{1F4B0} $${data.costUsd.toFixed(4)}`;
    const tokenParts: string[] = [];
    if (data.inputTokens != null) tokenParts.push(`${formatTokenCount(data.inputTokens)} in`);
    if (data.outputTokens != null) tokenParts.push(`${formatTokenCount(data.outputTokens)} out`);
    if (data.cacheReadTokens != null && data.cacheReadTokens > 0) tokenParts.push(`${formatTokenCount(data.cacheReadTokens)} cache`);
    const tokenStr = tokenParts.length > 0 ? ` | ${tokenParts.join(", ")}` : "";
    lines.push(`${costStr}${tokenStr}`);

    return lines.join("\n");
  }

  private buildPanel(): string {
    const elapsed = formatElapsed(Date.now() - this.startTime);
    const lines: string[] = [];

    // Header with timer
    lines.push(`${this.headerLabel} \u2014 ${elapsed}`);
    lines.push("");

    if (this.eventCount === 0 && !this.latestStatusText) {
      lines.push("Starting up...");
      return lines.join("\n");
    }

    // Counts line
    lines.push(this.buildCountsLine());

    // Status text line
    if (this.latestStatusText) {
      lines.push("");
      lines.push(`\u{1F4AC} ${this.latestStatusText}`);
    }

    return lines.join("\n");
  }

  private buildCountsLine(): string {
    const parts: string[] = [];
    parts.push(`\u270F\uFE0F ${this.editCount} edits`);
    parts.push(`\u{1F4C2} ${this.readCount} reads`);
    parts.push(`\u25B6\uFE0F ${this.commandCount} commands`);
    return parts.join("  ");
  }
}
