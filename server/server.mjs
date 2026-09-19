#!/usr/bin/env node
// MCP server for godot-mcp-bridge. Forwards MCP tool calls to a running
// Godot editor over a local TCP bridge (see addon/godot_mcp_bridge), and
// additionally exposes a few CLI-based tools (build/boot-check) that work
// even when the editor isn't open.
//
// Configuration (environment variables, all optional):
//   GODOT_PROJECT_PATH  Path to the folder containing project.godot.
//                        Defaults to the current working directory.
//   GODOT_BIN            Path to the Godot executable.
//                        Defaults to trying "godot4", "godot", "Godot" on PATH.
//   GODOT_MCP_PORT       TCP port the editor bridge listens on.
//                        Must match Project Settings > Mcp Bridge > Port.
//                        Defaults to 8756.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";

const HOST = "127.0.0.1";
const PORT = Number(process.env.GODOT_MCP_PORT || 8756);
const PROJECT_PATH = path.resolve(process.env.GODOT_PROJECT_PATH || process.cwd());

let reqCounter = 0;

function bridgeRequest(payload, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const id = ++reqCounter;
    const socket = net.createConnection({ host: HOST, port: PORT });
    let buffer = "";
    let settled = false;

    const finish = (fn, arg) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      fn(arg);
    };

    const timer = setTimeout(() => {
      finish(reject, new Error(
        `Timed out waiting for the Godot editor bridge on 127.0.0.1:${PORT}. ` +
        "Is the project open in the Godot editor with the godot_mcp_bridge plugin enabled?",
      ));
    }, timeoutMs);

    socket.on("connect", () => {
      socket.write(JSON.stringify({ id, ...payload }) + "\n");
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const nl = buffer.indexOf("\n");
      if (nl === -1) return;
      const line = buffer.slice(0, nl);
      try {
        finish(resolve, JSON.parse(line));
      } catch (err) {
        finish(reject, new Error("Invalid response from Godot bridge: " + line));
      }
    });

    socket.on("error", (err) => {
      if (err.code === "ECONNREFUSED") {
        finish(reject, new Error(
          `Could not reach the Godot editor bridge on 127.0.0.1:${PORT}. ` +
          "Open your project in the Godot editor (not just the game) with the " +
          "godot_mcp_bridge plugin enabled in Project Settings > Plugins.",
        ));
      } else {
        finish(reject, err);
      }
    });
  });
}

function toolDefToMcp(def) {
  const schema = def.parameters || { type: "object", properties: {} };
  if (!schema.properties) schema.properties = {};
  return { name: def.name, description: def.description || def.name, inputSchema: schema };
}

// --- Local (CLI) tools: work even when the editor isn't open. ---

function findGodotBinary() {
  if (process.env.GODOT_BIN) return process.env.GODOT_BIN;
  for (const candidate of ["godot4", "godot", "Godot"]) {
    const probe = spawnSync(candidate, ["--version"], { timeout: 5000 });
    if (!probe.error) return candidate;
  }
  return null;
}

// On Apple Silicon, a universal Godot binary launched from a shell running
// under Rosetta (common when the default terminal isn't native arm64) picks
// the x86_64 slice, which then fails to load an arm64-only .NET runtime for
// C# projects. Force arm64 explicitly so this doesn't depend on the calling
// shell's architecture.
function godotSpawnArgs(godotBin, args) {
  if (process.platform !== "darwin") return { cmd: godotBin, args };
  try {
    const probe = spawnSync("sysctl", ["-n", "hw.optional.arm64"], { timeout: 5000 });
    if (probe.stdout?.toString().trim() === "1") {
      return { cmd: "arch", args: ["-arm64", godotBin, ...args] };
    }
  } catch { /* ignore, fall through */ }
  return { cmd: godotBin, args };
}

function runProcess(cmd, args, cwd, timeoutMs = 180000) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd, timeout: timeoutMs });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.on("error", (err) => resolve({ code: -1, stdout, stderr: stderr + "\n" + err.message }));
  });
}

function formatShellResult(r) {
  const parts = [`exit code: ${r.code}`];
  if (r.stdout) parts.push("--- stdout (tail) ---\n" + r.stdout.slice(-6000));
  if (r.stderr) parts.push("--- stderr (tail) ---\n" + r.stderr.slice(-3000));
  return { content: [{ type: "text", text: parts.join("\n\n") }], isError: r.code !== 0 };
}

function findCSharpProject() {
  const entries = fs.readdirSync(PROJECT_PATH);
  return entries.find((f) => f.endsWith(".sln")) || entries.find((f) => f.endsWith(".csproj"));
}

const LOCAL_TOOLS = {
  godot_build: {
    description:
      "Compiles the project's C# code with `dotnet build` and returns the exact compiler errors/warnings. Only useful for C# (Mono/.NET) Godot projects. Works even if the editor isn't open.",
    inputSchema: { type: "object", properties: {} },
    run: async () => {
      const proj = findCSharpProject();
      if (!proj) {
        return { content: [{ type: "text", text: "No .sln/.csproj found in " + PROJECT_PATH + " — this doesn't look like a C# project, nothing to build." }] };
      }
      return formatShellResult(await runProcess("dotnet", ["build", proj], PROJECT_PATH, 300000));
    },
  },
  godot_check_boot: {
    description:
      "Boots the project headless for a few seconds and reports any SCRIPT ERROR / ERROR lines from stderr, catching startup crashes (bad autoloads, broken main scene, parse errors) without opening a window or the editor. Requires a Godot executable to be discoverable (see GODOT_BIN).",
    inputSchema: {
      type: "object",
      properties: { seconds: { type: "integer", description: "How many seconds to let it run before quitting (default 5)." } },
    },
    run: async (args) => {
      const godot = findGodotBinary();
      if (!godot) {
        return { content: [{ type: "text", text: "Could not find a Godot executable. Set GODOT_BIN to its full path." }], isError: true };
      }
      const seconds = Number(args?.seconds) || 5;
      const { cmd, args: spawnArgs } = godotSpawnArgs(godot, ["--headless", "--path", PROJECT_PATH, "--quit-after", String(seconds)]);
      const r = await runProcess(cmd, spawnArgs, PROJECT_PATH, (seconds + 30) * 1000);
      const problems = (r.stdout + "\n" + r.stderr).split("\n").filter((l) => /SCRIPT ERROR|^ERROR:|Parse Error/.test(l));
      const text = problems.length
        ? "Found problems:\n" + problems.join("\n")
        : `No script/parse errors detected in ${seconds}s headless boot.\n\n` + formatShellResult(r).content[0].text;
      return { content: [{ type: "text", text }], isError: problems.length > 0 };
    },
  },
};

const server = new Server(
  { name: "godot-mcp-bridge", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  const tools = Object.entries(LOCAL_TOOLS).map(([name, def]) => ({
    name,
    description: def.description,
    inputSchema: def.inputSchema,
  }));

  try {
    const resp = await bridgeRequest({ cmd: "list_tools" });
    if (!resp.error) tools.push(...(resp.result || []).map(toolDefToMcp));
  } catch (err) {
    console.error("[godot-mcp-bridge] editor tools unavailable: " + err.message);
  }

  return { tools };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (LOCAL_TOOLS[name]) {
    try {
      return await LOCAL_TOOLS[name].run(args || {});
    } catch (err) {
      return { content: [{ type: "text", text: "Error: " + err.message }], isError: true };
    }
  }

  let resp;
  try {
    resp = await bridgeRequest({ cmd: "call_tool", name, args: args || {} });
  } catch (err) {
    return { content: [{ type: "text", text: "Error: " + err.message }], isError: true };
  }
  if (resp.error) {
    return { content: [{ type: "text", text: "Error: " + resp.error }], isError: true };
  }

  const result = resp.result || {};
  const content = [];
  content.push({ type: "text", text: result.ok ? (result.output || "(tool executed, no output)") : "Error: " + result.error });

  if (result.image_path) {
    try {
      const data = fs.readFileSync(result.image_path);
      content.push({ type: "image", data: data.toString("base64"), mimeType: "image/png" });
    } catch (err) {
      content.push({ type: "text", text: "(image was captured but could not be read from disk: " + err.message + ")" });
    }
  }

  return { content, isError: !result.ok };
});

const transport = new StdioServerTransport();
await server.connect(transport);
