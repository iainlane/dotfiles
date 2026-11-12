import { SEGMENTS } from "#footer/rendering/segments.ts";
import {
  SEGMENT_IDS,
  isSegmentId,
  type SegmentId,
} from "#footer/configuration/settings.ts";
export const COMMANDS = [
  {
    name: "explain",
    grammar: "explain [widget]",
    description: "Explain the displayed footer or one widget",
  },
  {
    name: "config",
    grammar: "config",
    description: "Preview and customise the footer",
  },
  {
    name: "help",
    grammar: "help",
    description: "Commands, widget catalogue and navigation",
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
      error: `Unknown footer command '${command}'. Choose explain [widget], config or help. Example: /footer explain context`,
    };
  }
  if (command === "explain") {
    if (words.length > 2 || (segment !== undefined && !isSegmentId(segment))) {
      return {
        error: `Expected /footer explain [widget]. Valid widgets: ${SEGMENT_IDS.join(", ")}`,
      };
    }
    return {
      view: "explain",
      segment: isSegmentId(segment) ? segment : undefined,
    };
  }
  if (words.length > 1) {
    return {
      error: `/footer ${command} takes no arguments. Open /footer config to customise the footer.`,
    };
  }
  return { view: command === "config" ? "config" : "help" };
}
export function commandHelp(): string[] {
  return [
    ...COMMANDS.map(
      (command) => `/footer ${command.grammar}: ${command.description}`,
    ),
    "/footer explain cache: Explain one widget",
    "/footer: Same as /footer explain",
  ];
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
