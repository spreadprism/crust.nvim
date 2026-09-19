/**
 * Bundled with crust.nvim and passed to pi as `-e extensions/nvim.ts`
 * when `config.extension.enabled` is true.
 *
 * It talks back to the neovim instance that spawned pi over the socket in
 * CRUST_NVIM_SERVER, calling `crust.integrations.extension` functions with
 * `nvim --server <socket> --remote-expr`. Editor state reaches the LLM as a
 * hidden message on every turn, plus two tools for detail on demand.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const SERVER = process.env.CRUST_NVIM_SERVER;

export default function (pi: ExtensionAPI) {
  if (!SERVER) return;

  /** Call a lua expression in neovim, returning its string result. */
  async function remote(
    lua: string,
    signal?: AbortSignal,
  ): Promise<string | null> {
    const result = await pi.exec(
      "nvim",
      [
        "--server",
        SERVER!,
        "--remote-expr",
        `luaeval("${lua.replace(/"/g, '\\"')}")`,
      ],
      { signal, timeout: 5000 },
    );
    if (result.code !== 0) return null;
    return result.stdout.trim() || null;
  }

  pi.on("before_agent_start", async (_event, ctx) => {
    const snapshot = await remote(
      "require('crust.integrations.extension').snapshot()",
      ctx.signal,
    );
    if (!snapshot) return;

    return {
      message: {
        customType: "crust-nvim",
        content: `Current neovim state (crust.nvim):\n\`\`\`json\n${snapshot}\n\`\`\``,
        display: false,
      },
    };
  });

  pi.registerTool({
    name: "nvim_context",
    label: "Neovim Context",
    description:
      "Read the live state of the user's neovim instance: cwd, listed buffers, the current buffer, and the cursor position.",
    promptSnippet:
      "Inspect the user's open buffers and cursor position in neovim",
    promptGuidelines: [
      "Use nvim_context when the user refers to what they are looking at, 'this file', or 'here'.",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal) {
      const snapshot = await remote(
        "require('crust.integrations.extension').snapshot()",
        signal,
      );
      if (!snapshot) throw new Error("neovim did not answer on " + SERVER);
      return { content: [{ type: "text", text: snapshot }], details: {} };
    },
  });

  pi.registerTool({
    name: "nvim_diagnostics",
    label: "Neovim Diagnostics",
    description:
      "Read LSP diagnostics from the user's neovim instance, for one file or for every loaded buffer.",
    promptSnippet: "Read LSP diagnostics from the user's neovim instance",
    promptGuidelines: [
      "Use nvim_diagnostics after editing code to see what the user's language server reports.",
    ],
    parameters: Type.Object({
      path: Type.Optional(
        Type.String({
          description: "File to report on, omit for every buffer",
        }),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const arg = params.path ? `'${params.path.replace(/'/g, "''")}'` : "";
      const output = await remote(
        `require('crust.integrations.extension').diagnostics(${arg})`,
        signal,
      );
      if (!output) throw new Error("neovim did not answer on " + SERVER);
      return { content: [{ type: "text", text: output }], details: {} };
    },
  });
}
