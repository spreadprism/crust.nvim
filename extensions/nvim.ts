/**
 * Bundled with crust.nvim and passed to pi as `-e extensions/nvim.ts`
 * when `config.extension.enabled` is true.
 *
 * It talks back to the neovim instance that spawned pi over the socket in
 * CRUST_NVIM_SERVER, calling `crust.integrations.extension` functions with
 * `nvim --server <socket> --remote-expr`. The lua side of the wiring lives in
 * `lua/crust/extension.lua`.
 *
 * This file knows nothing about the individual tools. At startup it asks
 * neovim for `require('crust.integrations.extension').manifest()`, a json
 * array of tool specs, registers each one, and routes every call back to
 * `...call(name, args)`. Adding or changing a tool is a lua-only change under
 * `lua/crust/integrations/extension/`.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { readFileSync, unlinkSync } from "node:fs";

const SERVER = process.env.CRUST_NVIM_SERVER;

/**
 * Read the session token crust wrote for us and remove every trace of it: the
 * file is deleted and the variable dropped from our environment, so nothing pi
 * spawns later (the bash tool included) can see it. Without the token neovim
 * answers `{"error": "unauthorized"}`, which makes the socket alone useless.
 */
function readToken(): string | null {
  const path = process.env.CRUST_NVIM_TOKEN_FILE;
  delete process.env.CRUST_NVIM_TOKEN_FILE;
  if (!path) return null;

  try {
    const token = readFileSync(path, "utf8").trim();
    return token || null;
  } catch {
    return null;
  } finally {
    try {
      unlinkSync(path);
    } catch {
      // Already gone, or never ours to delete.
    }
  }
}

const TOKEN = readToken();

/** One entry of the manifest returned by the lua side. */
type ToolSpec = {
  name: string;
  label?: string;
  description: string;
  /** Json schema, object at the top level. */
  parameters?: Record<string, unknown>;
  promptSnippet?: string;
  promptGuidelines?: string[];
  /** Inject the result as hidden context before every turn. */
  context?: boolean;
};

export default function (pi: ExtensionAPI) {
  if (!SERVER || !TOKEN) return;

  /** Embed lua in `luaeval("…")`, itself inside a vimscript double-quoted string. */
  function expr(lua: string): string {
    return `luaeval("${lua.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}")`;
  }

  /** Escape a value for a lua single-quoted string literal. */
  function quote(value: string): string {
    return value
      .replace(/\\/g, "\\\\")
      .replace(/'/g, "\\'")
      .replace(/\n/g, "\\n");
  }

  /** Call a lua expression in neovim, returning its string result. */
  async function remote(
    lua: string,
    signal?: AbortSignal,
  ): Promise<string | null> {
    const result = await pi.exec(
      "nvim",
      ["--server", SERVER!, "--remote-expr", expr(lua)],
      {
        signal,
        timeout: 5000,
      },
    );
    if (result.code !== 0) return null;
    return result.stdout.trim() || null;
  }

  /**
   * Same call, blocking: the manifest is needed before the first turn, and
   * tools have to be registered while the extension is still loading.
   */
  function remoteSync(lua: string): string | null {
    try {
      const stdout = execFileSync(
        "nvim",
        ["--server", SERVER!, "--remote-expr", expr(lua)],
        {
          timeout: 5000,
          encoding: "utf8",
        },
      );
      return stdout.trim() || null;
    } catch {
      return null;
    }
  }

  const manifest = remoteSync(
    `require('crust.integrations.extension').manifest('${quote(TOKEN)}')`,
  );
  if (!manifest) return;

  let tools: ToolSpec[];
  try {
    tools = JSON.parse(manifest);
  } catch {
    return;
  }
  if (!Array.isArray(tools)) return;

  /** Run a tool in neovim; arguments travel as a json object string. */
  async function call(
    name: string,
    params: unknown,
    signal?: AbortSignal,
  ): Promise<string | null> {
    const args = quote(JSON.stringify(params ?? {}));
    return remote(
      `require('crust.integrations.extension').call('${quote(TOKEN!)}', '${quote(name)}', '${args}')`,
      signal,
    );
  }

  for (const tool of tools) {
    if (!tool?.name || !tool.description) continue;

    pi.registerTool({
      name: tool.name,
      label: tool.label ?? tool.name,
      description: tool.description,
      promptSnippet: tool.promptSnippet,
      promptGuidelines: tool.promptGuidelines,
      // The lua side ships plain json schema, which is what typebox emits too.
      parameters: (tool.parameters ?? {
        type: "object",
        properties: {},
      }) as never,
      async execute(_toolCallId, params, signal) {
        if (signal?.aborted)
          return { content: [{ type: "text", text: "Cancelled" }] };
        const result = await call(tool.name, params, signal);
        if (result === null)
          throw new Error(`neovim did not answer on ${SERVER}`);
        return { content: [{ type: "text", text: result }] };
      },
    });
  }

  const injected = tools.filter((tool) => tool.context);
  if (injected.length === 0) return;

  pi.on("before_agent_start", async (_event, ctx) => {
    const sections: string[] = [];
    for (const tool of injected) {
      const result = await call(tool.name, {}, ctx.signal);
      if (result) sections.push(`${tool.name}:\n\`\`\`json\n${result}\n\`\`\``);
    }
    if (sections.length === 0) return;

    return {
      message: {
        customType: "crust-nvim",
        content: `Current neovim state (crust.nvim):\n${sections.join("\n")}`,
        display: false,
      },
    };
  });
}
