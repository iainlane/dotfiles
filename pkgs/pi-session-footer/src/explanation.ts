import type { RenderFrame } from "./render.ts";
import { SEGMENTS } from "./segments.ts";
import {
  PRESETS,
  REGIONS,
  SEGMENT_IDS,
  type LoadedSettings,
  type Preset,
  type SegmentId,
} from "./settings.ts";
import { text } from "./text.ts";

export function frameSummary(frame: RenderFrame | undefined): string[] {
  return frame
    ? [
        `Completed render: ${new Date(frame.at).toISOString()}`,
        `Owner mode: ${frame.mode}; usable columns: top ${frame.top.width}, bottom ${frame.bottom.width}`,
        "Values below were captured during that render, not recalculated at inspector width.",
      ]
    : ["No completed render is available yet."];
}
export function explainSegment(
  frame: RenderFrame | undefined,
  id: SegmentId,
): string[] {
  const def = SEGMENTS[id];
  const reading = frame?.readings[id];
  const lines = [
    def.title,
    `Symbols: ${reading?.symbols ?? def.symbols}`,
    ...frameSummary(frame),
  ];

  if (reading !== undefined && frame !== undefined) {
    lines.push(
      `Reading: ${reading.state}${reading.reason ? `; ${reading.reason}` : ""}`,
      ...reading.parts.map(
        (part) => `${part.key}: ${text(part.variants[0], 2000)}`,
      ),
    );

    for (const decision of frame.decisions) {
      if (decision.id !== id) {
        continue;
      }

      let line = `${decision.region} · ${decision.child}: ${decision.decision}`;

      if (decision.display) {
        line += ` · ${text(decision.display, 2000)}`;
      }

      if (decision.reason) {
        line += ` (${decision.reason})`;
      }

      lines.push(line);
    }

    if (frame.disabled.includes(id)) {
      lines.push("Disabled: excluded by effective configuration");
    }

    lines.push(...reading.details);
  }

  lines.push(
    `Default priority: ${def.priority}. ${def.variants}.`,
    "Open the corresponding live domain view for additional source details; live data may differ from this captured frame.",
  );

  return lines;
}
export function configurationLines(settings: LoadedSettings): string[] {
  const repeats = SEGMENT_IDS.flatMap((id) => {
    const placements = REGIONS.filter((region) =>
      settings.regions[region].includes(id),
    );
    return placements.length > 1
      ? [
          `Repeated ${id}: ${placements.join(", ")} (each placement is intentional and fitted separately)`,
        ]
      : [];
  });
  return [
    `File: ${settings.path}`,
    `Source: ${settings.source}; preset: ${settings.preset}`,
    ...(settings.diagnostic !== undefined && settings.diagnostic !== ""
      ? [settings.diagnostic]
      : []),
    "Read-only: this inspector never applies presets or writes settings. Edit JSON externally and use native /reload.",
    `Symbols: ${JSON.stringify(Object.fromEntries(settings.symbols))}`,
    ...REGIONS.map(
      (region) =>
        `${region} (${settings.overridden.includes(region) ? "overridden" : "inherited"}): ${JSON.stringify(settings.regions[region])}`,
    ),
    ...repeats,
    "An omitted region inherits; [] disables it. Arrays replace rather than append. Repetition is allowed across regions, not within one region.",
    "Supported segments:",
    ...SEGMENT_IDS.map(
      (id) =>
        `${id}: ${SEGMENTS[id].title} · ${id === "planning" ? settings.symbols.get("planning") : id === "statuses" ? settings.symbols.get("default") : SEGMENTS[id].symbols}`,
    ),
    'Home Manager override: home.file.".pi/agent/session-footer.json".text = lib.mkForce (builtins.toJSON { preset = "compact"; });',
  ];
}
export function presetLines(preset: Preset): string[] {
  return [
    `Preset ${preset} · passive preview only, not active settings`,
    JSON.stringify({ preset }, null, 2),
    ...REGIONS.map(
      (region) => `${region}: ${JSON.stringify(PRESETS[preset][region])}`,
    ),
  ];
}
