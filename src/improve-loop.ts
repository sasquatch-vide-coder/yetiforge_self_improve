/**
 * Self-improvement loop — autonomous plan-execute cycles.
 *
 * `/improve [count] [direction]` launches a loop that runs N iterations,
 * each consisting of:  plan (evaluator picks an improvement) -> execute -> commit.
 *
 * The `/improve` command IS the blanket approval — no per-iteration user confirmation.
 * Same pattern as the cron trigger handler: executor.plan() then executor.execute() directly.
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { Executor } from "./agents/executor.js";
import { InvocationLogger } from "./status/invocation-logger.js";
import { ChatLocks } from "./middleware/rate-limit.js";
import { StreamFormatter } from "./utils/stream-formatter.js";
import { sendLongMessage } from "./utils/telegram.js";
import { buildImproveEvaluatorPrompt, buildImproveExecutorPrompt } from "./agents/prompts.js";
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
  maxCostUsd: number;
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

  try {
    for (let i = state.completedIterations; i < state.totalIterations; i++) {
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

      // ── Cost circuit breaker ──
      if (state.totalCostUsd >= state.maxCostUsd) {
        state.status = "paused";
        state.pauseReason = `Cost limit reached ($${state.totalCostUsd.toFixed(2)} / $${state.maxCostUsd.toFixed(2)})`;
        store.set(chatId, state);
        await sendMsg(`Improve loop paused: ${state.pauseReason}\n\nUse /improve resume to continue.`);
        return;
      }

      const iterNum = i + 1;

      // ── PLAN PHASE ──
      state.currentPhase = "planning";
      store.set(chatId, state);

      await sendMsg(`Iteration ${iterNum}/${state.totalIterations} \u2014 Planning...`);

      const historyText = compactHistory(state.history);
      const evaluatorPrompt = buildImproveEvaluatorPrompt(
        state.direction,
        historyText,
        iterNum,
        state.totalIterations,
      );

      let planResult;
      try {
        // Briefly mark idle so /cancel can fire, then re-mark busy
        chatLocks.setExecutorIdle(chatId);
        if (abortSignal.aborted) { state.status = "cancelled"; store.set(chatId, state); return; }
        chatLocks.setExecutorBusy(chatId);

        planResult = await executor.plan({
          chatId,
          task: evaluatorPrompt,
          context: "",
          complexity: "moderate",
          rawMessage: `[improve loop iteration ${iterNum}/${state.totalIterations}]`,
          cwd: state.projectDir,
          abortSignal,
          onInvocation: (raw) => logInvocation(raw, chatId, "executor-plan", invocationLogger),
        });
      } catch (err: any) {
        if (abortSignal.aborted) { state.status = "cancelled"; store.set(chatId, state); return; }
        logger.error({ chatId, iteration: iterNum, err }, "Improve loop plan failed");
        consecutiveFailures++;
        state.history.push({
          iteration: iterNum,
          summary: `Plan failed: ${err.message?.slice(0, 100)}`,
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
        await sendMsg(`Iteration ${iterNum} plan failed: ${err.message?.slice(0, 100)}`);
        await delay(INTER_ITERATION_DELAY_MS);
        continue;
      }

      state.totalCostUsd += planResult.costUsd;

      // ── EXECUTE PHASE ──
      state.currentPhase = "executing";
      store.set(chatId, state);

      const executorSystemPrompt = buildImproveExecutorPrompt(serviceName, iterNum, state.totalIterations);

      // Build the execution task with the plan baked in
      const execTask = `${executorSystemPrompt}\n\n## Plan from Evaluator\n\n${planResult.planText}`;

      let execResult;
      try {
        // Briefly mark idle so /cancel can fire, then re-mark busy
        chatLocks.setExecutorIdle(chatId);
        if (abortSignal.aborted) { state.status = "cancelled"; store.set(chatId, state); return; }
        chatLocks.setExecutorBusy(chatId);

        const formatter = new StreamFormatter(`Improve #${iterNum}`);

        execResult = await executor.execute({
          chatId,
          task: execTask,
          context: `Improve loop iteration ${iterNum}/${state.totalIterations}`,
          complexity: "moderate",
          rawMessage: `[improve loop iteration ${iterNum}/${state.totalIterations}]`,
          cwd: state.projectDir,
          abortSignal,
          onStreamEvent: (event) => formatter.addEvent(event),
          onInvocation: (raw) => logInvocation(raw, chatId, "executor", invocationLogger),
        });
      } catch (err: any) {
        if (abortSignal.aborted) { state.status = "cancelled"; store.set(chatId, state); return; }
        logger.error({ chatId, iteration: iterNum, err }, "Improve loop execute failed");
        consecutiveFailures++;
        state.history.push({
          iteration: iterNum,
          summary: `Execute failed: ${err.message?.slice(0, 100)}`,
          success: false,
          costUsd: planResult.costUsd,
          durationMs: planResult.durationMs,
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
        await sendMsg(`Iteration ${iterNum} execute failed: ${err.message?.slice(0, 100)}`);
        await delay(INTER_ITERATION_DELAY_MS);
        continue;
      }

      // ── Record result ──
      const totalIterCost = planResult.costUsd + execResult.costUsd;
      const totalIterDuration = planResult.durationMs + execResult.durationMs;
      state.totalCostUsd += execResult.costUsd;

      // Extract a one-line summary from the result (first non-empty line or truncated)
      const summary = extractSummary(execResult.result);

      state.history.push({
        iteration: iterNum,
        summary,
        success: execResult.success,
        costUsd: totalIterCost,
        durationMs: totalIterDuration,
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
      const durSec = Math.round(totalIterDuration / 1000);
      const cost = totalIterCost.toFixed(4);
      await sendMsg(`${icon} Iteration ${iterNum}/${state.totalIterations} (${durSec}s, $${cost})\n${summary}`);

      if (consecutiveFailures >= CONSECUTIVE_FAILURE_LIMIT) {
        state.status = "paused";
        state.pauseReason = `${CONSECUTIVE_FAILURE_LIMIT} consecutive failures`;
        store.set(chatId, state);
        await sendMsg(`Improve loop paused: ${state.pauseReason}\n\nUse /improve resume to continue.`);
        return;
      }

      // ── Inter-iteration delay ──
      if (i < state.totalIterations - 1) {
        await delay(INTER_ITERATION_DELAY_MS);
      }
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
