/**
 * Self-improvement loop — autonomous evaluate-implement-commit cycles.
 *
 * `/improve [count] [direction]` launches a loop that runs N iterations,
 * each using a single CLI session to: evaluate the codebase, pick an improvement,
 * implement it, and commit — all in one pass.
 *
 * The `/improve` command IS the blanket approval — no per-iteration user confirmation.
 */

import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from "fs";
import { join, dirname } from "path";
import { Executor } from "./agents/executor.js";
import { InvocationLogger } from "./status/invocation-logger.js";
import { ChatLocks } from "./middleware/rate-limit.js";
import { StreamFormatter, FinalSummaryData } from "./utils/stream-formatter.js";
import { sendLongMessage } from "./utils/telegram.js";
import { buildImproveIterationPrompt, buildImproveStrategicPlanPrompt } from "./agents/prompts.js";
import { logger } from "./utils/logger.js";

// ─── State Types ────────────────────────────────────────────────────────────────

export interface ImproveIterationRecord {
  iteration: number;
  summary: string;
  success: boolean;
  costUsd: number;
  durationMs: number;
}

export interface ImproveLoopState {
  chatId: number;
  direction: string | null;
  totalIterations: number;
  completedIterations: number;
  status: "running" | "stopping" | "stopped" | "paused" | "completed" | "cancelled" | "failed";
  projectDir: string;
  history: ImproveIterationRecord[];
  totalCostUsd: number;
  startedAt: number;
  currentPhase: "planning" | "executing" | "idle";
  pauseReason: string | null;
  batchSize: number;
  strategicPlan: string | null;
  strategicPlanCostUsd: number;
}

// ─── ImproveLoopStore ───────────────────────────────────────────────────────────

export class ImproveLoopStore {
  private loops = new Map<number, ImproveLoopState>();
  private filePath: string | null = null;

  constructor(dataDir?: string) {
    if (dataDir) {
      this.filePath = join(dataDir, "improve-loops.json");
    }
  }

  load(): void {
    if (!this.filePath) return;
    try {
      const raw = readFileSync(this.filePath, "utf-8");
      const entries: [number, ImproveLoopState][] = JSON.parse(raw);
      this.loops = new Map(entries);
      if (this.loops.size > 0) {
        logger.info({ count: this.loops.size }, "Loaded improve loop states from disk");
      }
    } catch {
      this.loops = new Map();
    }
  }

  set(chatId: number, state: ImproveLoopState): void {
    this.loops.set(chatId, state);
    this.saveToDisk();
  }

  get(chatId: number): ImproveLoopState | null {
    return this.loops.get(chatId) || null;
  }

  remove(chatId: number): void {
    this.loops.delete(chatId);
    this.saveToDisk();
  }

  hasActive(chatId: number): boolean {
    const state = this.loops.get(chatId);
    return !!state && (state.status === "running" || state.status === "stopping");
  }

  getAllActive(): ImproveLoopState[] {
    return Array.from(this.loops.values()).filter(
      (s) => s.status === "running" || s.status === "stopping",
    );
  }

  private saveToDisk(): void {
    if (!this.filePath) return;
    try {
      mkdirSync(dirname(this.filePath), { recursive: true });
      writeFileSync(this.filePath, JSON.stringify(Array.from(this.loops.entries()), null, 2));
    } catch (err) {
      logger.error({ err }, "Failed to persist improve loop states to disk");
    }
  }
}

// ─── History Compaction ─────────────────────────────────────────────────────────

function compactHistory(history: ImproveIterationRecord[]): string {
  if (history.length === 0) return "No previous iterations.";

  const lines: string[] = [];

  // Older iterations: one-liners
  if (history.length > 3) {
    for (let i = 0; i < history.length - 3; i++) {
      const h = history[i];
      const icon = h.success ? "+" : "-";
      lines.push(`[${icon}] #${h.iteration}: ${h.summary}`);
    }
    lines.push("");
  }

  // Last 3 iterations: full detail
  const recent = history.slice(-3);
  for (const h of recent) {
    const icon = h.success ? "OK" : "FAIL";
    const cost = h.costUsd.toFixed(4);
    const dur = Math.round(h.durationMs / 1000);
    lines.push(`#${h.iteration} [${icon}] (${dur}s, $${cost}): ${h.summary}`);
  }

  return lines.join("\n");
}

// ─── File Tree Generator ────────────────────────────────────────────────────────

const FILE_TREE_SKIP = new Set(["node_modules", "dist", ".git", "data"]);
const FILE_TREE_SKIP_EXT = new Set([".log"]);
const FILE_TREE_MAX_DEPTH = 4;
const FILE_TREE_MAX_ENTRIES = 200;

function generateFileTree(rootDir: string): string {
  const lines: string[] = [];
  let count = 0;

  function walk(dir: string, prefix: string, depth: number): void {
    if (depth > FILE_TREE_MAX_DEPTH || count >= FILE_TREE_MAX_ENTRIES) return;

    let entries: string[];
    try {
      entries = readdirSync(dir).sort();
    } catch {
      return;
    }

    for (const entry of entries) {
      if (count >= FILE_TREE_MAX_ENTRIES) {
        lines.push(`${prefix}... (truncated)`);
        return;
      }

      if (FILE_TREE_SKIP.has(entry) || entry.startsWith(".env")) continue;
      if (FILE_TREE_SKIP_EXT.has(entry.slice(entry.lastIndexOf(".")))) continue;

      const fullPath = join(dir, entry);
      let isDir = false;
      try {
        isDir = statSync(fullPath).isDirectory();
      } catch {
        continue;
      }

      lines.push(`${prefix}${entry}${isDir ? "/" : ""}`);
      count++;

      if (isDir) {
        walk(fullPath, prefix + "  ", depth + 1);
      }
    }
  }

  walk(rootDir, "", 0);
  return lines.join("\n");
}

// ─── Progress Panel Helpers ──────────────────────────────────────────────────────

const PANEL_UPDATE_INTERVAL_MS = 4000;

/**
 * Safe edit using raw bot API (no grammY ctx available in improve loop).
 * Skips if text hasn't changed; falls back from Markdown to plain text.
 */
async function safeEditRaw(
  api: any,
  chatId: number,
  messageId: number,
  text: string,
  lastText: { value: string },
): Promise<void> {
  if (text === lastText.value) return;
  const truncated = text.length > 4096 ? text.slice(0, 4093) + "..." : text;
  try {
    await api.editMessageText(chatId, messageId, truncated, { parse_mode: "Markdown" });
    lastText.value = text;
  } catch {
    try {
      await api.editMessageText(chatId, messageId, truncated);
      lastText.value = text;
    } catch { /* identical text or deleted message — ignore */ }
  }
}

// ─── Batch Planning ─────────────────────────────────────────────────────────────

async function planBatch(opts: {
  state: ImproveLoopState;
  store: ImproveLoopStore;
  executor: Executor;
  invocationLogger: InvocationLogger;
  chatLocks: ChatLocks;
  botApi: any;
  abortSignal: AbortSignal;
  serviceName: string;
  batchItemCount: number;
  fileTree?: string;
}): Promise<{ plan: string; costUsd: number } | null> {
  const { state, store, executor, invocationLogger, chatLocks, botApi, abortSignal, serviceName, batchItemCount, fileTree } = opts;
  const chatId = state.chatId;

  state.currentPhase = "planning";
  store.set(chatId, state);

  const planPrompt = buildImproveStrategicPlanPrompt(serviceName, state.direction, batchItemCount, fileTree);

  // Send a progress message for planning
  let progressMessageId: number | null = null;
  const formatter = new StreamFormatter(`\uD83D\uDCCB Planning batch (${batchItemCount} items)`);
  const lastEditText = { value: "" };

  try {
    const msg = await botApi.api.sendMessage(chatId, `\uD83D\uDCCB Planning batch of ${batchItemCount} improvements...`);
    progressMessageId = msg.message_id;
  } catch (err) {
    logger.warn({ chatId, err }, "Failed to send batch planning progress message");
  }

  let panelInterval: ReturnType<typeof setInterval> | null = null;
  if (progressMessageId) {
    panelInterval = setInterval(async () => {
      if (!progressMessageId) return;
      const panel = formatter.render();
      if (panel) {
        await safeEditRaw(botApi.api, chatId, progressMessageId, panel, lastEditText).catch(() => {});
      }
    }, PANEL_UPDATE_INTERVAL_MS);
  }

  try {
    // Briefly mark idle so /cancel can fire, then re-mark busy
    chatLocks.setExecutorIdle(chatId);
    if (abortSignal.aborted) return null;
    chatLocks.setExecutorBusy(chatId);

    const planResult = await executor.plan({
      chatId,
      task: planPrompt,
      context: `Strategic planning for batch of ${batchItemCount} improvements`,
      complexity: "moderate",
      rawMessage: `[improve loop strategic planning]`,
      cwd: state.projectDir,
      abortSignal,
      onStreamEvent: (event) => formatter.addEvent(event),
      onInvocation: (raw) => {
        logInvocation(raw, chatId, "executor-plan", invocationLogger);
      },
    });

    if (panelInterval) clearInterval(panelInterval);

    // Update progress message with final result
    if (progressMessageId) {
      const finalPanel = formatter.renderFinalSummary({
        costUsd: planResult.costUsd,
        durationMs: planResult.durationMs,
        success: true,
      });
      lastEditText.value = "";
      await safeEditRaw(botApi.api, chatId, progressMessageId, finalPanel, lastEditText).catch(() => {});
    }

    return { plan: planResult.planText, costUsd: planResult.costUsd };
  } catch (err: any) {
    if (panelInterval) clearInterval(panelInterval);

    if (progressMessageId) {
      const errorPanel = formatter.renderFinalSummary({
        costUsd: 0,
        durationMs: 0,
        success: false,
      });
      lastEditText.value = "";
      await safeEditRaw(botApi.api, chatId, progressMessageId, errorPanel, lastEditText).catch(() => {});
    }

    logger.error({ chatId, err }, "Batch strategic planning failed");
    return null;
  }
}

// ─── Core Loop ──────────────────────────────────────────────────────────────────

const CONSECUTIVE_FAILURE_LIMIT = 3;
const INTER_ITERATION_DELAY_MS = 5000;

export async function runImproveLoop(opts: {
  state: ImproveLoopState;
  store: ImproveLoopStore;
  executor: Executor;
  invocationLogger: InvocationLogger;
  chatLocks: ChatLocks;
  botApi: any;
  abortSignal: AbortSignal;
  serviceName: string;
}): Promise<void> {
  const { state, store, executor, invocationLogger, chatLocks, botApi, abortSignal, serviceName } = opts;
  const chatId = state.chatId;

  const sendMsg = async (text: string) => {
    try {
      await sendLongMessage(botApi.api, chatId, text);
    } catch (err) {
      logger.warn({ chatId, err }, "Failed to send improve loop message");
    }
  };

  let consecutiveFailures = 0;
  let fileTree: string | undefined;
  const batchSize = state.batchSize;
  const skipPlanning = state.totalIterations <= 1;

  try {
    for (let i = state.completedIterations; i < state.totalIterations; ) {
      // ── Check cancellation / stopping ──
      if (abortSignal.aborted || state.status === "cancelled") {
        state.status = "cancelled";
        store.set(chatId, state);
        await sendMsg(`Improve loop cancelled after ${state.completedIterations}/${state.totalIterations} iterations.`);
        return;
      }

      if (state.status === "stopping") {
        state.status = "stopped";
        store.set(chatId, state);
        await sendMsg(buildSummary(state, "Stopped gracefully"));
        return;
      }

      // ── Determine batch boundaries ──
      const remaining = state.totalIterations - i;
      const batchItemCount = Math.min(batchSize, remaining);

      // ── Batch Planning Phase ──
      // Skip planning for single-iteration runs or if already have a plan for this batch
      const needsPlan = !skipPlanning && !state.strategicPlan;

      if (needsPlan) {
        // Refresh file tree for planning
        fileTree = generateFileTree(state.projectDir);

        const planResult = await planBatch({
          state, store, executor, invocationLogger, chatLocks,
          botApi, abortSignal, serviceName, batchItemCount, fileTree,
        });

        if (abortSignal.aborted || (state.status as string) === "cancelled") {
          state.status = "cancelled";
          store.set(chatId, state);
          return;
        }

        if (planResult) {
          state.strategicPlan = planResult.plan;
          state.strategicPlanCostUsd += planResult.costUsd;
          state.totalCostUsd += planResult.costUsd;
          store.set(chatId, state);
          await sendMsg(`\uD83D\uDCCB Strategic plan ready ($${planResult.costUsd.toFixed(4)}). Executing ${batchItemCount} items...`);
        } else {
          // Planning failed — fall back to unguided iterations for this batch
          state.strategicPlan = null;
          store.set(chatId, state);
          await sendMsg(`\u26A0\uFE0F Planning failed — falling back to unguided iterations for this batch.`);
        }
      }

      // ── Execute batch iterations ──
      const batchEnd = Math.min(i + batchItemCount, state.totalIterations);

      for (let j = i; j < batchEnd; j++) {
        // ── Check cancellation / stopping (status mutated externally by /improve stop|cancel) ──
        if (abortSignal.aborted || (state.status as string) === "cancelled") {
          state.status = "cancelled";
          store.set(chatId, state);
          await sendMsg(`Improve loop cancelled after ${state.completedIterations}/${state.totalIterations} iterations.`);
          return;
        }

        if ((state.status as string) === "stopping") {
          state.status = "stopped";
          store.set(chatId, state);
          await sendMsg(buildSummary(state, "Stopped gracefully"));
          return;
        }

        const iterNum = j + 1;
        const batchItemNumber = j - i + 1; // 1-based index within current batch

        // ── Refresh file tree every 5 iterations ──
        if (iterNum === 1 || iterNum % 5 === 0) {
          fileTree = generateFileTree(state.projectDir);
        }

        // ── EXECUTE (single session: evaluate → implement → commit) ──
        state.currentPhase = "executing";
        store.set(chatId, state);

        const historyText = compactHistory(state.history);

        // Build strategic plan context for this iteration
        const strategicContext = state.strategicPlan
          ? { fullPlan: state.strategicPlan, itemNumber: batchItemNumber }
          : null;

        const iterationPrompt = buildImproveIterationPrompt(
          serviceName,
          state.direction,
          historyText,
          iterNum,
          state.totalIterations,
          fileTree,
          strategicContext,
        );

        let execResult;
        let panelInterval: ReturnType<typeof setInterval> | null = null;
        let progressMessageId: number | null = null;
        const formatter = new StreamFormatter(`\u2699\uFE0F Iteration ${iterNum}/${state.totalIterations}`);
        const lastEditText = { value: "" };

        // Capture token data from invocation
        let capturedTokens: { inputTokens?: number; outputTokens?: number; cacheReadTokens?: number } = {};

        try {
          // Briefly mark idle so /cancel can fire, then re-mark busy
          chatLocks.setExecutorIdle(chatId);
          if (abortSignal.aborted) { state.status = "cancelled"; store.set(chatId, state); return; }
          chatLocks.setExecutorBusy(chatId);

          // Send initial progress message and capture message_id for in-place editing
          try {
            const msg = await botApi.api.sendMessage(chatId, `\u2699\uFE0F Iteration ${iterNum}/${state.totalIterations} \u2014 0m 0s\n\nStarting up...`);
            progressMessageId = msg.message_id;
          } catch (err) {
            logger.warn({ chatId, err }, "Failed to send improve progress message");
          }

          // Set up 4s interval to edit the progress message with live panel
          if (progressMessageId) {
            panelInterval = setInterval(async () => {
              if (!progressMessageId) return;
              const panel = formatter.render();
              if (panel) {
                await safeEditRaw(botApi.api, chatId, progressMessageId, panel, lastEditText).catch(() => {});
              }
            }, PANEL_UPDATE_INTERVAL_MS);
          }

          execResult = await executor.execute({
            chatId,
            task: iterationPrompt,
            context: `Improve loop iteration ${iterNum}/${state.totalIterations}`,
            complexity: "moderate",
            rawMessage: `[improve loop iteration ${iterNum}/${state.totalIterations}]`,
            cwd: state.projectDir,
            abortSignal,
            onStreamEvent: (event) => formatter.addEvent(event),
            onStatusUpdate: async (update) => {
              if (update.important) {
                try {
                  await botApi.api.sendMessage(chatId, update.message, { parse_mode: "Markdown" });
                } catch {
                  await botApi.api.sendMessage(chatId, update.message.replace(/[*_`]/g, "")).catch(() => {});
                }
              }
            },
            onInvocation: (raw) => {
              logInvocation(raw, chatId, "executor", invocationLogger);

              // Capture token data for final summary
              const entry = Array.isArray(raw)
                ? raw.find((item: any) => item.type === "result") || raw[0]
                : raw;
              if (entry) {
                const usage = entry.modelUsage || entry.model_usage;
                if (usage) {
                  capturedTokens.inputTokens = usage.input_tokens || usage.inputTokens;
                  capturedTokens.outputTokens = usage.output_tokens || usage.outputTokens;
                  capturedTokens.cacheReadTokens = usage.cache_read_input_tokens || usage.cacheReadInputTokens;
                }
              }
            },
          });
        } catch (err: any) {
          // Clean up progress panel on error
          if (panelInterval) clearInterval(panelInterval);
          panelInterval = null;

          // Render final error panel
          if (progressMessageId) {
            const errorPanel = formatter.renderFinalSummary({
              costUsd: 0,
              durationMs: Date.now() - (state.startedAt || Date.now()),
              success: false,
            });
            lastEditText.value = "";
            await safeEditRaw(botApi.api, chatId, progressMessageId, errorPanel, lastEditText).catch(() => {});
          }

          if (abortSignal.aborted) { state.status = "cancelled"; store.set(chatId, state); return; }
          logger.error({ chatId, iteration: iterNum, err }, "Improve loop iteration failed");
          consecutiveFailures++;
          state.history.push({
            iteration: iterNum,
            summary: `Failed: ${err.message?.slice(0, 100)}`,
            success: false,
            costUsd: 0,
            durationMs: 0,
          });
          state.completedIterations = iterNum;
          store.set(chatId, state);

          if (consecutiveFailures >= CONSECUTIVE_FAILURE_LIMIT) {
            state.status = "paused";
            state.pauseReason = `${CONSECUTIVE_FAILURE_LIMIT} consecutive failures`;
            store.set(chatId, state);
            await sendMsg(`Improve loop paused: ${state.pauseReason}\n\nUse /improve resume to continue.`);
            return;
          }
          await sendMsg(`Iteration ${iterNum} failed: ${err.message?.slice(0, 100)}`);
          await delay(INTER_ITERATION_DELAY_MS);
          continue;
        }

        // ── Clean up progress panel ──
        if (panelInterval) clearInterval(panelInterval);

        // Render final summary panel on the progress message
        if (progressMessageId) {
          const finalPanel = formatter.renderFinalSummary({
            costUsd: execResult.costUsd,
            durationMs: execResult.durationMs,
            success: execResult.success,
            ...capturedTokens,
          });
          lastEditText.value = "";
          await safeEditRaw(botApi.api, chatId, progressMessageId, finalPanel, lastEditText).catch(() => {});
        }

        // ── Record result ──
        state.totalCostUsd += execResult.costUsd;

        // Extract a one-line summary from the result (first non-empty line or truncated)
        const summary = extractSummary(execResult.result);

        state.history.push({
          iteration: iterNum,
          summary,
          success: execResult.success,
          costUsd: execResult.costUsd,
          durationMs: execResult.durationMs,
        });
        state.completedIterations = iterNum;
        state.currentPhase = "idle";
        store.set(chatId, state);

        if (execResult.success) {
          consecutiveFailures = 0;
        } else {
          consecutiveFailures++;
        }

        const icon = execResult.success ? "\u2705" : "\u274C";
        const durSec = Math.round(execResult.durationMs / 1000);
        const cost = execResult.costUsd.toFixed(4);
        await sendMsg(`${icon} Iteration ${iterNum}/${state.totalIterations} (${durSec}s, $${cost})\n${summary}`);

        if (consecutiveFailures >= CONSECUTIVE_FAILURE_LIMIT) {
          state.status = "paused";
          state.pauseReason = `${CONSECUTIVE_FAILURE_LIMIT} consecutive failures`;
          store.set(chatId, state);
          await sendMsg(`Improve loop paused: ${state.pauseReason}\n\nUse /improve resume to continue.`);
          return;
        }

        // ── Inter-iteration delay ──
        if (j < state.totalIterations - 1) {
          await delay(INTER_ITERATION_DELAY_MS);
        }
      }

      // ── Advance past this batch ──
      i = batchEnd;

      // Clear strategic plan so next batch gets a fresh one
      state.strategicPlan = null;
      store.set(chatId, state);
    }

    // ── All iterations complete ──
    state.status = "completed";
    state.currentPhase = "idle";
    store.set(chatId, state);
    await sendMsg(buildSummary(state, "Completed"));
  } finally {
    chatLocks.setExecutorIdle(chatId);
    state.currentPhase = "idle";

    // Clean up completed/cancelled/failed loops from the store after a delay
    // (keep paused/stopped for resume)
    if (state.status === "completed" || state.status === "cancelled" || state.status === "failed") {
      // Keep in store for status queries, but mark as terminal
      store.set(chatId, state);
    }
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────────

function extractSummary(result: string): string {
  // Take first non-empty line, capped at 200 chars
  const lines = result.split("\n").filter((l) => l.trim());
  const first = lines[0] || "No summary available";
  return first.length > 200 ? first.slice(0, 197) + "..." : first;
}

function buildSummary(state: ImproveLoopState, label: string): string {
  const lines: string[] = [];
  const totalDuration = Date.now() - state.startedAt;
  const durMin = Math.round(totalDuration / 60000);
  const cost = state.totalCostUsd.toFixed(4);

  lines.push(`\u{1F3C1} Improve Loop ${label}`);
  lines.push(`${state.completedIterations}/${state.totalIterations} iterations | ${durMin}m | $${cost}`);

  if (state.direction) {
    lines.push(`Direction: ${state.direction}`);
  }

  if (state.strategicPlanCostUsd > 0) {
    lines.push(`Planning cost: $${state.strategicPlanCostUsd.toFixed(4)}`);
  }

  if (state.batchSize > 1 && state.totalIterations > 1) {
    lines.push(`Batch size: ${state.batchSize}`);
  }

  lines.push("");

  const successes = state.history.filter((h) => h.success).length;
  const failures = state.history.filter((h) => !h.success).length;
  lines.push(`Results: ${successes} succeeded, ${failures} failed`);
  lines.push("");

  for (const h of state.history) {
    const icon = h.success ? "\u2705" : "\u274C";
    lines.push(`${icon} #${h.iteration}: ${h.summary}`);
  }

  return lines.join("\n");
}

function logInvocation(raw: any, chatId: number, tier: string, invocationLogger: InvocationLogger): void {
  const entry = Array.isArray(raw)
    ? raw.find((item: any) => item.type === "result") || raw[0]
    : raw;
  if (entry) {
    if (Array.isArray(raw)) {
      const e = raw.find((item: any) => item.type === "result") || raw[0];
      if (e) e._tier = tier;
    } else {
      raw._tier = tier;
    }
    invocationLogger.log({
      timestamp: Date.now(),
      chatId,
      tier,
      durationMs: entry.durationms || entry.duration_ms,
      durationApiMs: entry.durationapims || entry.duration_api_ms,
      costUsd: entry.totalcostusd || entry.total_cost_usd || entry.cost_usd,
      numTurns: entry.numturns || entry.num_turns,
      stopReason: entry.subtype || entry.stopreason || entry.stop_reason,
      isError: entry.iserror || entry.is_error || false,
      modelUsage: entry.modelUsage || entry.model_usage,
    }).catch(() => {});
  }
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
