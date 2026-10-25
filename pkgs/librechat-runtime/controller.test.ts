import { StatusCodes } from "http-status-codes";
import { expect, it } from "vitest";
import { ControllerRouter } from "./controller.ts";
import type { Session } from "./sessions.ts";
import { runtimeIdentity } from "./identity.ts";

const userId = "0123456789abcdef01234567";

const conversationId = "ea277865-9bbd-45ec-9cd2-234cf9dc9169";

const token = "a".repeat(64);

function fixture(): { router: ControllerRouter; events: string[] } {
  const events: string[] = [];

  const session: Session = {
    userId,
    conversationId,
    runtimeId: runtimeIdentity(userId, conversationId),
    generation: 2,
    lastUsed: 0,
    checkpoint: true,
    expired: false,
    resetReason: "Restored workspace.",
    quarantine: null,
  };

  const router = new ControllerRouter({
    userId,
    token,
    sessions: {
      activate: async (owner, conversation) => {
        events.push(`activate:${owner}:${conversation}`);

        return session;
      },
      reset: async (runtime) => {
        events.push(`reset:${runtime}`);
      },
    },
    mcp: { route: async () => Response.json({}) },
  });

  return { router, events };
}

it("answers health probes without renewing a workspace", async () => {
  const { router, events } = fixture();

  const response = await router.route(new Request("http://controller/health"));

  const body: unknown = await response.json();

  expect({ status: response.status, body, events }).toStrictEqual({
    status: StatusCodes.OK,
    body: { status: "ready" },
    events: [],
  });
});

it.each([
  {
    authorization: "Bearer incorrect",
    conversationId,
    status: StatusCodes.UNAUTHORIZED,
  },
  {
    authorization: `Bearer ${token}`,
    conversationId: "invalid",
    status: StatusCodes.BAD_REQUEST,
  },
])(
  "rejects invalid activation before acquiring a workspace: %j",
  async ({ authorization, conversationId: selectedConversation, status }) => {
    const { router, events } = fixture();

    const response = await router.route(
      new Request("http://controller/activate", {
        method: "POST",
        headers: { authorization, "content-type": "application/json" },
        body: JSON.stringify({ conversationId: selectedConversation }),
      }),
    );

    expect({ status: response.status, events }).toStrictEqual({
      status,
      events: [],
    });
  },
);

it("resets the server-derived runtime for the personal account", async () => {
  const { router, events } = fixture();

  const response = await router.route(
    new Request("http://controller/reset", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        conversationId,
        runtimeId: "untrusted",
        userId: "another-owner",
      }),
    }),
  );

  const body: unknown = await response.json();

  expect({ status: response.status, body, events }).toStrictEqual({
    status: StatusCodes.OK,
    body: { status: "reset" },
    events: [`reset:${runtimeIdentity(userId, conversationId)}`],
  });
});
