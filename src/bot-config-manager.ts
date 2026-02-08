import { readFile, writeFile, mkdir } from "fs/promises";
import { join } from "path";
import { logger } from "./utils/logger.js";

export interface BotConfigData {
  botName: string;
  serviceName: string;
  agentName: string;
}

const DEFAULT_CONFIG: BotConfigData = {
  botName: "YETIFORGE",
  serviceName: "yetiforge",
  agentName: "yetiforge",
};

export class BotConfigManager {
  private config: BotConfigData = structuredClone(DEFAULT_CONFIG);
  private filePath: string;

  constructor(dataDir: string) {
    this.filePath = join(dataDir, "bot-config.json");
  }

  async load(): Promise<void> {
    try {
      const raw = await readFile(this.filePath, "utf-8");
      const data = JSON.parse(raw) as Partial<BotConfigData>;
      // Merge with defaults so new fields are always present
      this.config = {
        ...DEFAULT_CONFIG,
        ...data,
      };
      logger.info("Bot config loaded");
    } catch {
      logger.info("No existing bot config, using defaults");
    }
  }

  async save(): Promise<void> {
    await mkdir(join(this.filePath, ".."), { recursive: true });
    await writeFile(this.filePath, JSON.stringify(this.config, null, 2));
    logger.debug("Bot config saved");
  }

  getBotName(): string {
    return this.config.botName;
  }

  setBotName(name: string): void {
    this.config.botName = name;
  }

  getServiceName(): string {
    return this.config.serviceName;
  }

  setServiceName(name: string): void {
    this.config.serviceName = name;
  }

  getAgentName(): string {
    return this.config.agentName;
  }

  setAgentName(name: string): void {
    this.config.agentName = name;
  }

  /**
   * Generate CLAUDE.md from the template file, replacing placeholders
   * with the current bot configuration values.
   */
  async generateClaudeMd(projectRoot: string): Promise<void> {
    const templatePath = join(projectRoot, "CLAUDE.md.template");
    const outputPath = join(projectRoot, "CLAUDE.md");

    try {
      let template = await readFile(templatePath, "utf-8");

      const botName = this.config.botName;
      template = template
        .replaceAll("{{BOT_NAME}}", botName)
        .replaceAll("{{BOT_NAME_UPPER}}", botName.toUpperCase())
        .replaceAll("{{BOT_NAME_LOWER}}", botName.toLowerCase())
        .replaceAll("{{SERVICE_NAME}}", this.config.serviceName)
        .replaceAll("{{AGENT_NAME}}", this.config.agentName);

      await writeFile(outputPath, template);
      logger.info("CLAUDE.md generated from template");
    } catch (err) {
      logger.error({ err }, "Failed to generate CLAUDE.md from template");
    }
  }
}
