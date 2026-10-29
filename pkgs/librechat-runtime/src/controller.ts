import { StatusCodes } from "http-status-codes";
import { z } from "zod";
import { authorised, McpRouter } from "./mcp-router.ts";
import { ConversationIdError } from "./errors.ts";
import { runtimeIdentity } from "./identity.ts";
import type { Session, SessionManager } from "./sessions.ts";

export function workspaceReminder(session: Session): string {
  return [
    ...(session.quarantine === null
      ? []
      : [
          "Workspace access is unavailable after a recovery failure. Ask the user to inspect the last checkpoint before resetting the workspace.",
        ]),
    `Conversation workspace generation: ${session.generation}. ${session.resetReason}`,
    "Code Interpreter uses /mnt/data. Local MCP servers use the same Linux VM and filesystem. Host files and credentials are not mounted in the VM.",
    "The VM starts only when a tool or workspace file operation needs it. Selected tools determine which operations are available in this chat. The VM stops after 15 minutes without active calls. Files resume from a committed checkpoint; processes and browser tabs restart. A crash may lose changes since the last completed checkpoint.",
    "Workspace retention extends on conversation activity. After 30 days without activity the workspace is deleted, including unpushed Git changes.",
    "Shared skills and their scripts are available in /usr/share/agent-skills. When a skill refers to shell or file tools from another client, use Code Interpreter with Bash or Python in /mnt/data.",
    "Public HTTP(S) uses the egress proxy. GitHub credentials are injected by the host proxy. AgentsView access is read-only; remote MCP services use their own host connections.",
  ].join("\n");
}

interface ControllerOptions {
  userId: string;
  token: string;
  sessions: Pick<SessionManager, "register" | "reset">;
  mcp: Pick<McpRouter, "route">;
}

export class ControllerRouter {
  private readonly options: ControllerOptions;

  constructor(options: ControllerOptions) {
    this.options = options;
  }

  async route(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;

    if (path === "/health" && request.method === "GET") {
      return Response.json({ status: "ready" });
    }

    if (path.startsWith("/mcp/")) {
      return await this.options.mcp.route(request);
    }

    if (!authorised(request.headers.get("authorization"), this.options.token)) {
      return new Response(null, { status: StatusCodes.UNAUTHORIZED });
    }

    if (request.method !== "POST" || !["/activity", "/reset"].includes(path)) {
      return new Response(null, { status: StatusCodes.NOT_FOUND });
    }

    let raw: unknown;

    try {
      raw = await request.json();
    } catch (error) {
      if (!(error instanceof SyntaxError)) {
        throw error;
      }
    }

    const body = z.object({ conversationId: z.uuid() }).safeParse(raw);

    if (!body.success) {
      const error = new ConversationIdError();

      return Response.json(
        { error: error.name, message: error.message },
        { status: StatusCodes.BAD_REQUEST },
      );
    }

    if (path === "/reset") {
      await this.options.sessions.reset(
        runtimeIdentity(this.options.userId, body.data.conversationId),
      );

      return Response.json({ status: "reset" });
    }

    const session = await this.options.sessions.register(
      this.options.userId,
      body.data.conversationId,
      request.signal,
    );

    return Response.json({ additionalContext: workspaceReminder(session) });
  }
}
