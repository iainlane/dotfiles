import { SEGMENTS } from "./segments.ts";
import { SEGMENT_IDS, isSegmentId, type SegmentId } from "./settings.ts";
export const COMMANDS = [
  {
    name: "explain",
    grammar: "explain [segment]",
    description:
      "Explain the most recent completed display; bare /footer also opens this view",
  },
  {
    name: "config",
    grammar: "config",
    description: "Inspect configuration and browse passive preset previews",
  },
  {
    name: "help",
    grammar: "help",
    description: "Command grammar, configuration and navigation",
  },
] as const;
export type FooterRoute =
  | { view: "explain"; segment: SegmentId | undefined }
  | { view: "config" | "help" };
export function parseFooterCommand(
  args: string,
): FooterRoute | { error: string } {
  const words = args.trim().split(/\s+/).filter(Boolean);
  const [command = "explain", segment] = words;
  const definition = COMMANDS.find(({ name }) => name === command);
  if (!definition) {
    return {
      error: `Unknown footer command '${command}'. Choose explain [segment], config or help. Example: /footer explain context`,
    };
  }
  if (command === "explain") {
    if (words.length > 2 || (segment !== undefined && !isSegmentId(segment))) {
      return {
        error: `Expected /footer explain [segment]. Valid segments: ${SEGMENT_IDS.join(", ")}`,
      };
    }
    return {
      view: "explain",
      segment: isSegmentId(segment) ? segment : undefined,
    };
  }
  if (words.length > 1) {
    return {
      error: `/footer ${command} takes no arguments. Preset browsing is inside /footer config.`,
    };
  }
  return { view: command === "config" ? "config" : "help" };
}
export function commandHelp(): string[] {
  return COMMANDS.map(
    (command) => `/footer ${command.grammar}: ${command.description}`,
  );
}
export function completeFooter(
  prefix: string,
): { value: string; label: string; description: string }[] | null {
  const candidates = prefix.startsWith("explain ")
    ? SEGMENT_IDS.map((id) => ({
        value: `explain ${id}`,
        label: id,
        description: SEGMENTS[id].title,
      }))
    : COMMANDS.map((command) => ({
        value: command.name,
        label: command.name,
        description: command.description,
      }));
  const matches = candidates.filter(({ value }) => value.startsWith(prefix));
  return matches.length > 0 ? matches : null;
}
