import { readFile, writeFile, mkdir } from "fs/promises";
import { readdirSync, statSync } from "fs";
import { join } from "path";
import { logger } from "../utils/logger.js";

/** Marker files that indicate a directory is a project root. */
export const PROJECT_MARKERS = [
  "package.json", ".git", "Cargo.toml", "go.mod",
  "pyproject.toml", "pom.xml", "Makefile", ".sln",
  "Gemfile", "composer.json",
];

interface ProjectsData {
  projects: Record<string, string>; // name → path
  activeProject: Record<string, string>; // chatId → project name
}

export class ProjectManager {
  private projects = new Map<string, string>();
  private activeProject = new Map<number, string>();
  private filePath: string;
  private defaultDir: string;

  constructor(dataDir: string, defaultDir: string) {
    this.filePath = join(dataDir, "projects.json");
    this.defaultDir = defaultDir;
  }

  async load(): Promise<void> {
    try {
      const raw = await readFile(this.filePath, "utf-8");
      const data: ProjectsData = JSON.parse(raw);
      for (const [name, path] of Object.entries(data.projects || {})) {
        this.projects.set(name, path);
      }
      for (const [chatId, name] of Object.entries(data.activeProject || {})) {
        this.activeProject.set(parseInt(chatId, 10), name);
      }
      logger.info({ count: this.projects.size }, "Projects loaded");
    } catch {
      logger.info("No existing projects file, starting fresh");
    }
  }

  async save(): Promise<void> {
    const data: ProjectsData = {
      projects: Object.fromEntries(this.projects),
      activeProject: Object.fromEntries(
        Array.from(this.activeProject.entries()).map(([k, v]) => [String(k), v])
      ),
    };
    await mkdir(join(this.filePath, ".."), { recursive: true });
    await writeFile(this.filePath, JSON.stringify(data, null, 2));
    logger.debug("Projects saved");
  }

  list(): Map<string, string> {
    return new Map(this.projects);
  }

  add(name: string, path: string): void {
    this.projects.set(name, path);
  }

  remove(name: string): boolean {
    return this.projects.delete(name);
  }

  getActiveProjectName(chatId: number): string | undefined {
    return this.activeProject.get(chatId);
  }

  getActiveProjectDir(chatId: number): string | undefined {
    const name = this.activeProject.get(chatId);
    if (!name) return this.defaultDir;
    return this.projects.get(name) || this.defaultDir;
  }

  switchProject(chatId: number, name: string): string | undefined {
    const path = this.projects.get(name);
    if (!path) return undefined;
    this.activeProject.set(chatId, name);
    return path;
  }

  clearActive(chatId: number): void {
    this.activeProject.delete(chatId);
  }

  /**
   * Scan a directory for project-like subdirectories and auto-register them.
   * Returns stats about what was found.
   */
  scan(baseDir?: string): { added: string[]; existing: string[]; total: number } {
    const dir = baseDir || this.defaultDir;
    const added: string[] = [];
    const existing: string[] = [];

    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      logger.warn({ dir }, "Cannot scan directory for projects");
      return { added, existing, total: this.projects.size };
    }

    for (const entry of entries) {
      if (entry.startsWith(".")) continue;

      const fullPath = join(dir, entry);
      let isDir = false;
      try {
        isDir = statSync(fullPath).isDirectory();
      } catch {
        continue;
      }
      if (!isDir) continue;

      // Check if this subdirectory has any project markers
      let hasMarker = false;
      for (const marker of PROJECT_MARKERS) {
        try {
          statSync(join(fullPath, marker));
          hasMarker = true;
          break;
        } catch {
          // marker doesn't exist
        }
      }

      if (!hasMarker) continue;

      const name = entry;
      if (this.projects.has(name)) {
        existing.push(name);
      } else {
        this.add(name, fullPath);
        added.push(name);
      }
    }

    if (added.length > 0) {
      this.save().catch((err) => logger.error({ err }, "Failed to save after project scan"));
      logger.info({ added, existing: existing.length, total: this.projects.size }, "Project scan complete");
    }

    return { added, existing, total: this.projects.size };
  }

  /**
   * Build a compact context string listing all projects and marking the active one.
   * Returns empty string if no projects registered.
   */
  getProjectListForPrompt(chatId: number): string {
    if (this.projects.size === 0) return "";

    const projectList = Array.from(this.projects.entries())
      .map(([name, path]) => `${name} (${path})`)
      .join(", ");

    const activeName = this.activeProject.get(chatId) || "(none)";

    return `[PROJECT CONTEXT]\nAvailable projects: ${projectList}\nActive project: ${activeName}`;
  }
}
