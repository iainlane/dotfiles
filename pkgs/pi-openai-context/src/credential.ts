import { readFile } from "node:fs/promises";
import { type Static, Type } from "typebox";
import { Check } from "typebox/value";
import { chatGptCredentialSchema } from "./schemas.ts";

export type ChatGptCredential = Static<typeof chatGptCredentialSchema>;

export type CredentialRead =
  | { status: "present"; credential: ChatGptCredential }
  | { status: "absent" }
  | { status: "unavailable" };

const authSchema = Type.Object({ openai: Type.Optional(Type.Unknown()) });
const apiKeySchema = Type.Object({ type: Type.Literal("api_key") });

export function classifyCredential(value: unknown): CredentialRead {
  if (value === undefined || Check(apiKeySchema, value)) {
    return { status: "absent" };
  }
  return Check(chatGptCredentialSchema, value)
    ? { status: "present", credential: value }
    : { status: "unavailable" };
}

export async function readChatGptCredential(
  path: string,
): Promise<CredentialRead> {
  try {
    const data: unknown = JSON.parse(
      (await readFile(path, "utf8")).replace(/^\uFEFF/, ""),
    );
    if (Check(authSchema, data)) {
      return classifyCredential(data.openai);
    }
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return { status: "absent" };
    }
  }
  return { status: "unavailable" };
}
