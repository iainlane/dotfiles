import { createHash } from "node:crypto";

export const CODE_ENVIRONMENT_ID = "conversation-vm";

export const CODE_TENANT_ID = "dotfiles-librechat";

export interface ManifestPrincipal {
  user_id: string;
  tenant_id: string;
}

function opaqueLabel(prefix: string, value: string): string {
  const digest = createHash("sha256")
    .update(value, "utf8")
    .digest("base64url")
    .slice(0, 32);

  return `${prefix}:${digest}`;
}

/** Matches the sandbox-visible principal produced by CodeAPI's egress gateway. */
export function executionManifestPrincipal(userId: string): ManifestPrincipal {
  return {
    user_id: opaqueLabel("user", userId),
    tenant_id: opaqueLabel("tenant", CODE_TENANT_ID),
  };
}

function fingerprint(parts: string[]): string {
  return createHash("sha256").update(JSON.stringify(parts)).digest("hex");
}

/** Matches LibreChat 0.8.8's conversation scope and CodeAPI 1.10.13's identity. */
export function runtimeIdentity(
  userId: string,
  conversationId: string,
): string {
  const hint = `v3:${fingerprint([CODE_ENVIRONMENT_ID]).slice(0, 12)}:conversation:${fingerprint([userId, conversationId]).slice(0, 32)}`;

  const material = [CODE_TENANT_ID, userId, hint].join("\0");

  return `rt_${createHash("sha256").update(material).digest("hex").slice(0, 40)}`;
}
