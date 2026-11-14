import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type AssistantMessage,
  type FauxProviderHandle,
  type FauxResponseFactory,
  type Message,
  type Model,
  type ToolCall,
} from "@earendil-works/pi-ai";

/**
 * Creates Pi's faux provider for `model` and answers every request with
 * `respond`, which chooses the reply from the request's transcript.
 */
export function transcriptProvider(
  model: Model<string>,
  respond: FauxResponseFactory,
): FauxProviderHandle {
  const faux = fauxProvider({
    api: model.api,
    provider: model.provider,
    // Stream each block in one delta. Boundary-size plans would otherwise
    // produce hundreds of thousands of RPC events.
    tokenSize: { min: 1_000_000_000, max: 1_000_000_000 },
    models: [
      {
        id: model.id,
        name: model.name,
        reasoning: model.reasoning,
        input: model.input,
        cost: model.cost,
        contextWindow: model.contextWindow,
        maxTokens: model.maxTokens,
      },
    ],
  });
  // The faux provider takes one queued step for each request. Every queued
  // step is the same reply function and queues a copy of itself, so the queue
  // never runs out and its order never decides a reply.
  const step: FauxResponseFactory = (...request) => {
    faux.appendResponses([step]);
    return respond(...request);
  };
  faux.setResponses(Array.from({ length: 8 }, () => step));
  return faux;
}

/** A reply that calls one tool. */
export function toolCallReply(
  id: string,
  name: string,
  args: ToolCall["arguments"],
): AssistantMessage {
  return fauxAssistantMessage(fauxToolCall(name, args, { id }), {
    stopReason: "toolUse",
  });
}

/** The ID of the latest tool result in the transcript. */
export function lastToolResult(messages: Message[]): string | undefined {
  return messages.findLast((message) => message.role === "toolResult")
    ?.toolCallId;
}

/**
 * Splits the transcript at the run that is in progress. `prompt` is the text
 * of the user and extension messages that started the run, and `progress`
 * lists the replies and tool results since then.
 */
export function currentRun(messages: Message[]): {
  prompt: string;
  progress: Message[];
} {
  let end = messages.length;
  while (end > 0 && messages[end - 1]?.role !== "user") {
    end -= 1;
  }
  let start = end;
  while (start > 0 && messages[start - 1]?.role === "user") {
    start -= 1;
  }
  return {
    prompt: userText(messages.slice(start, end)),
    progress: messages.slice(end),
  };
}

/** The text of every user message in the transcript. */
export function userText(messages: Message[]): string {
  return messages
    .flatMap((message) =>
      message.role === "user" ? [JSON.stringify(message.content)] : [],
    )
    .join("\n");
}
