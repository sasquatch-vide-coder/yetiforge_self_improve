/**
 * In-memory store for pending plans, keyed by chatId.
 *
 * When the executor runs in "plan" mode, it produces a plan summary.
 * That plan is stored here until the user approves, revises, or cancels it.
 * On approval, the stored plan context is used to launch execution mode.
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { logger } from "./utils/logger.js";

export interface PendingPlan {
  chatId: number;
  /** The original task description from the work request */
  task: string;
  /** The original context from the work request */
  context: string;
  /** The plan text produced by the executor in plan mode */
  planText: string;
  /** Complexity level for timeout calculation */
  complexity: string;
  /** Project directory for execution */
  projectDir: string;
  /** Raw user message that triggered the plan */
  rawMessage: string;
  /** Memory context at the time of planning */
  memoryContext?: string;
  /** Timestamp when the plan was created */
  createdAt: number;
  /** How many times the plan has been revised */
  revisionCount: number;
}

export class PlanStore {
  private plans = new Map<number, PendingPlan>();
  private filePath: string | null = null;

  constructor(dataDir?: string) {
    if (dataDir) {
      this.filePath = join(dataDir, "pending-plans.json");
    }
  }

  /** Load pending plans from disk. Call on startup. */
  load(): void {
    if (!this.filePath) return;
    try {
      const raw = readFileSync(this.filePath, "utf-8");
      const entries: [number, PendingPlan][] = JSON.parse(raw);
      this.plans = new Map(entries);
      if (this.plans.size > 0) {
        logger.info({ count: this.plans.size }, "Loaded pending plans from disk");
      }
    } catch {
      this.plans = new Map();
    }
  }

  /** Store a pending plan for a chat. Replaces any existing plan. */
  set(chatId: number, plan: PendingPlan): void {
    this.plans.set(chatId, plan);
    this.saveToDisk();
    logger.info({ chatId, task: plan.task, revisionCount: plan.revisionCount }, "Pending plan stored");
  }

  /** Retrieve the pending plan for a chat, or null if none exists. */
  get(chatId: number): PendingPlan | null {
    return this.plans.get(chatId) || null;
  }

  /** Remove and return the pending plan for a chat. */
  consume(chatId: number): PendingPlan | null {
    const plan = this.plans.get(chatId) || null;
    if (plan) {
      this.plans.delete(chatId);
      this.saveToDisk();
      logger.info({ chatId, task: plan.task }, "Pending plan consumed");
    }
    return plan;
  }

  /** Check if a chat has a pending plan. */
  has(chatId: number): boolean {
    return this.plans.has(chatId);
  }

  /** Cancel (remove) a pending plan. */
  cancel(chatId: number): boolean {
    const had = this.plans.has(chatId);
    if (had) {
      this.plans.delete(chatId);
      this.saveToDisk();
      logger.info({ chatId }, "Pending plan cancelled");
    }
    return had;
  }

  /** Get all pending plan chat IDs (for debugging/admin). */
  allChatIds(): number[] {
    return Array.from(this.plans.keys());
  }

  /** Synchronous write — survives process death. */
  private saveToDisk(): void {
    if (!this.filePath) return;
    try {
      mkdirSync(dirname(this.filePath), { recursive: true });
      writeFileSync(this.filePath, JSON.stringify(Array.from(this.plans.entries()), null, 2));
    } catch (err) {
      logger.error({ err }, "Failed to persist pending plans to disk");
    }
  }
}
