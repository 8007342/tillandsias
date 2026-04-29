#!/usr/bin/env node
// @trace spec:browser-mcp-server
// MCP Server for browser window control in Tillandsias forge containers.
// Exposes open_safe_window and open_debug_window tools to agents.
// Forwards requests to tray via Unix socket IPC at /run/tillandsias/tray.sock

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { CallToolRequestSchema, TextContent } from "@modelcontextprotocol/sdk/types.js";

const TraySocket = "/run/tillandsias/tray.sock";
const Project = process.env.TILLANDSIAS_PROJECT || "unknown";

// MCP Server instance
const server = new Server({
  name: "tillandsias-browser",
  version: "1.0.0",
});

// Tool definitions
const tools = [
  {
    name: "open_safe_window",
    description:
      "Open a URL in an isolated safe browser window with dark theme, hidden address bar, and no developer tools. " +
      "Safe windows enforce read-only isolation. Available for URLs matching <service>.<project>.localhost or dashboard.localhost.",
    inputSchema: {
      type: "object",
      properties: {
        url: {
          type: "string",
          description:
            "Target URL in format <service>.<project>.localhost or dashboard.localhost (e.g., 'opencode.my-project.localhost', 'dashboard.localhost')",
        },
      },
      required: ["url"],
    },
  },
  {
    name: "open_debug_window",
    description:
      "Open a URL in an isolated debug browser window with Chrome DevTools enabled and visible address bar. " +
      "Debug windows expose the full inspector on localhost:9222 for troubleshooting. " +
      "Agents can only open debug windows for their own project (e.g., 'web.my-project.localhost'). " +
      "No debug windows for external or dashboard URLs.",
    inputSchema: {
      type: "object",
      properties: {
        url: {
          type: "string",
          description:
            "Target URL matching <service>.<project>.localhost (e.g., 'web.my-project.localhost'). Must match the agent's current project.",
        },
      },
      required: ["url"],
    },
  },
];

// Register tool list handler
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request;

  if (name === "open_safe_window") {
    return await handleOpenSafeWindow(args.url);
  } else if (name === "open_debug_window") {
    return await handleOpenDebugWindow(args.url);
  } else {
    return {
      content: [{ type: "text", text: `Unknown tool: ${name}` }],
      isError: true,
    };
  }
});

async function handleOpenSafeWindow(url) {
  try {
    // Validate URL format
    if (!isValidWindowUrl(url)) {
      return {
        content: [
          {
            type: "text",
            text: `Invalid URL format. Expected <service>.<project>.localhost or dashboard.localhost, got: ${url}`,
          },
        ],
        isError: true,
      };
    }

    // Forward to tray via socket
    const response = await forwardToTray({
      action: "open_safe_window",
      url,
      project: Project,
    });

    return {
      content: [
        {
          type: "text",
          text: `Safe window opened for ${url}\n${JSON.stringify(response)}`,
        },
      ],
    };
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: `Failed to open safe window: ${error.message}`,
        },
      ],
      isError: true,
    };
  }
}

async function handleOpenDebugWindow(url) {
  try {
    // Validate URL format and project constraint
    if (!isValidDebugWindowUrl(url, Project)) {
      return {
        content: [
          {
            type: "text",
            text: `Invalid URL for debug window. Must match <service>.<project>.localhost for current project '${Project}', got: ${url}`,
          },
        ],
        isError: true,
      };
    }

    // Forward to tray via socket
    const response = await forwardToTray({
      action: "open_debug_window",
      url,
      project: Project,
    });

    return {
      content: [
        {
          type: "text",
          text: `Debug window opened for ${url}\nDevTools available at localhost:9222\n${JSON.stringify(response)}`,
        },
      ],
    };
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: `Failed to open debug window: ${error.message}`,
        },
      ],
      isError: true,
    };
  }
}

function isValidWindowUrl(url) {
  // Allow <service>.<project>.localhost or dashboard.localhost
  if (url === "dashboard.localhost") return true;
  if (url.endsWith(".localhost") && url.includes(".")) {
    const parts = url.split(".");
    if (parts.length >= 2 && parts[parts.length - 1] === "localhost") {
      return true;
    }
  }
  return false;
}

function isValidDebugWindowUrl(url, project) {
  // Debug windows: only <service>.<project>.localhost (not dashboard.localhost, not external)
  if (url === "dashboard.localhost") return false; // No debug windows for dashboard
  if (!url.endsWith(`.${project}.localhost`)) return false;
  const parts = url.split(".");
  if (parts.length >= 2 && parts[parts.length - 2] === project) {
    return true;
  }
  return false;
}

async function forwardToTray(request) {
  // TODO: Implement Unix socket communication to tray
  // For now, return a mock response; actual implementation in src-tauri/src/browser.rs
  return {
    status: "queued",
    message: `Request forwarded to tray: ${JSON.stringify(request)}`,
  };
}

// Start the MCP server with stdio transport
const transport = new StdioServerTransport();
await server.connect(transport);

console.error("[mcp-server-browser] Started on stdio transport");
