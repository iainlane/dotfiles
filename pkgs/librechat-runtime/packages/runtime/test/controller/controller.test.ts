import { StatusCodes } from "http-status-codes";
import { expect, it } from "vitest";
import { ControllerRouter } from "#runtime/controller/controller";
import type { Session, SessionManager } from "#runtime/sessions/sessions";
import { runtimeIdentity } from "#runtime/platform/identity";

const userId = "0123456789abcdef01234567";

const conversationId = "ea277865-9bbd-45ec-9cd2-234cf9dc9169";

const token = "a".repeat(64);

const runtimeId = runtimeIdentity(userId, conversationId);

const session: Session = {
  userId,
  conversationId,
  runtimeId,
  generation: 2,
  lastUsed: 0,
  checkpoint: true,
  expired: false,
  resetReason: "Restored workspace.",
  quarantine: null,
};

class FixtureWorkspaces implements Pick<SessionManager, "register" | "reset"> {
  readonly sessions = new Map<string, Session>([[runtimeId, session]]);

  async register(owner: string, conversation: string): Promise<Session> {
    const id = runtimeIdentity(owner, conversation);
    const renewed: Session = {
      ...(this.sessions.get(id) ?? {
        ...session,
        userId: owner,
        conversationId: conversation,
        runtimeId: id,
        generation: 1,
      }),
      lastUsed: 100,
    };

    this.sessions.set(id, renewed);

    return renewed;
  }

  async reset(id: string): Promise<void> {
    this.sessions.delete(id);
  }
}

function fixture() {
  const workspaces = new FixtureWorkspaces();

  const router = new ControllerRouter({
    userId,
    token,
    sessions: workspaces,
    mcp: { route: async () => Response.json({}) },
  });

  return { router, workspaces: () => Object.fromEntries(workspaces.sessions) };
}

it("answers health probes without renewing a workspace", async () => {
  const { router, workspaces } = fixture();

  const response = await router.route(new Request("http://controller/health"));

  const body: unknown = await response.json();

  expect({
    status: response.status,
    body,
    workspaces: workspaces(),
  }).toStrictEqual({
    status: StatusCodes.OK,
    body: { status: "ready" },
    workspaces: { [runtimeId]: session },
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
  "rejects invalid registration before acquiring a workspace: %j",
  async ({ authorization, conversationId: selectedConversation, status }) => {
    const { router, workspaces } = fixture();

    const response = await router.route(
      new Request("http://controller/activity", {
        method: "POST",
        headers: { authorization, "content-type": "application/json" },
        body: JSON.stringify({ conversationId: selectedConversation }),
      }),
    );

    expect({
      status: response.status,
      workspaces: workspaces(),
    }).toStrictEqual({
      status,
      workspaces: { [runtimeId]: session },
    });
  },
);

it("resets the server-derived runtime for the personal account", async () => {
  const { router, workspaces } = fixture();

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

  expect({
    status: response.status,
    body,
    workspaces: workspaces(),
  }).toStrictEqual({
    status: StatusCodes.OK,
    body: { status: "reset" },
    workspaces: {},
  });
});
