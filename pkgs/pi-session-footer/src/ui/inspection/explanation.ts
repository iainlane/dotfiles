import { WIDGET_ROLES } from "#footer/configuration/appearance.ts";
import type {
  PlacementEvidence,
  RenderFrame,
} from "#footer/rendering/render.ts";
import { SEGMENTS } from "#footer/rendering/segments.ts";
import {
  REGION_LABELS,
  type Region,
  type SegmentId,
} from "#footer/configuration/settings.ts";

export interface LegendEntry {
  key: string;
  id: SegmentId;
  region: Region;
  value: string;
  description: string;
}
export interface CapturedField {
  region: Region;
  role: string;
  label: string;
  value: string;
}
const DESCRIPTIONS = {
  model: "Model",
  thinking: "Reasoning effort",
  tier: "Service tier",
  directory: "Current directory",
  git: "Git branch and file changes",
  "git-operation": "Git operation",
  "git-conflicts": "Git conflicts",
  pr: "Pull request",
  context: "Context used",
  activity: "Activity",
  diagnostics: "Diagnostic findings",
  tasks: "Task progress",
  blocked: "Blocked tasks",
  agents: "Child agents",
  pending: "Pending messages",
  planning: "Planning",
  ci: "Failed checks",
  reviews: "Unresolved review threads",
  statuses: "Extension messages",
  quota: "Quota used",
  cache: "Cache hit rate",
  cost: "Session cost",
  "auxiliary-cost": "Auxiliary cost",
  age: "Session age",
  input: "Input tokens",
  output: "Output tokens",
  "cache-read": "Cache read tokens",
  "cache-write": "Cache write tokens",
  "run-duration": "Current run duration",
  "active-duration": "Observed active-work time",
  "compaction-duration": "Compaction duration",
} satisfies Record<SegmentId, string>;

function roleFields(placement: PlacementEvidence): CapturedField[] {
  const roles = new Map<string, string>();
  for (const part of placement.parts) {
    let previous: string | undefined;
    for (const run of part.runs) {
      if (run.role !== undefined) {
        previous = run.role;
        roles.set(run.role, (roles.get(run.role) ?? "") + run.value);
        continue;
      }
      if (previous !== undefined && run.value.trim() === "") {
        roles.set(previous, (roles.get(previous) ?? "") + run.value);
        continue;
      }
      previous = undefined;
    }
  }
  return [...roles].flatMap(([role, value]) =>
    value.trim() === ""
      ? []
      : [
          {
            region: placement.region,
            role,
            label: WIDGET_ROLES[placement.id][role]?.label ?? role,
            value: value.trim(),
          },
        ],
  );
}
export class CapturedFooter {
  private readonly frame: RenderFrame | undefined;
  constructor(frame: RenderFrame | undefined) {
    this.frame =
      frame === undefined || frame.mode === "preview"
        ? undefined
        : structuredClone(frame);
  }
  get drawn(): boolean {
    return this.frame !== undefined;
  }
  private visible(id?: SegmentId): PlacementEvidence[] {
    return (
      this.frame?.placements.filter(
        (placement) =>
          placement.display !== "" && (id === undefined || placement.id === id),
      ) ?? []
    );
  }
  get entries(): LegendEntry[] {
    const placements = this.visible();
    return placements.map((placement) => {
      const repeated =
        placements.filter((other) => other.id === placement.id).length > 1;
      return {
        key: `${placement.region}:${placement.id}`,
        id: placement.id,
        region: placement.region,
        value: placement.display,
        description:
          DESCRIPTIONS[placement.id] +
          (repeated ? ` · ${REGION_LABELS[placement.region]}` : ""),
      };
    });
  }
  summary(id: SegmentId): string[] {
    return this.frame?.readings[id].summary ?? [];
  }
  fields(id: SegmentId): CapturedField[] {
    return this.visible(id).flatMap((placement) => roleFields(placement));
  }
  reason(id: SegmentId): string | undefined {
    const frame = this.frame;
    if (frame === undefined) {
      return "The footer has not drawn yet.";
    }
    if (this.visible(id).length > 0) {
      return undefined;
    }
    if (frame.disabled.includes(id)) {
      return "Not enabled in this layout.";
    }
    const reading = frame.readings[id];
    if (reading.state !== "available") {
      return reading.reason;
    }
    return "Omitted because the footer was too narrow.";
  }
  private placementDetails(placement: PlacementEvidence): string[] {
    const lines = [
      `${REGION_LABELS[placement.region]}: ${placement.budget} columns`,
      `Appearance: ${JSON.stringify(placement.appearance)}`,
    ];
    if (placement.gauge !== undefined) {
      lines.push(
        `Gauge: ${placement.gauge.value}`,
        `Gauge symbols: ${JSON.stringify(placement.gauge.symbols)}`,
      );
    }
    for (const part of placement.parts) {
      lines.push(
        `${part.key}: variant ${part.variant + 1}, priority ${part.priority}${part.detailPriority === undefined ? "" : `, detail priority ${part.detailPriority}`}`,
        `Symbols: ${JSON.stringify(part.symbols)}`,
      );
    }
    return lines;
  }
  technical(id: SegmentId): string[] {
    const frame = this.frame;
    if (frame === undefined) {
      return ["The footer has not drawn yet."];
    }
    const placements = frame.placements.filter(
      (placement) => placement.id === id,
    );
    return [
      `Captured: ${new Date(frame.at).toISOString()}`,
      `Owner: ${frame.mode}`,
      `Usable columns: top ${frame.top.width}, bottom ${frame.bottom.width}`,
      `Source symbols: ${frame.readings[id].symbols ?? SEGMENTS[id].symbols}`,
      ...placements.flatMap((placement) => this.placementDetails(placement)),
      ...frame.decisions
        .filter((decision) => decision.id === id)
        .map(
          (decision) =>
            `${REGION_LABELS[decision.region]} · ${decision.child}: ${decision.decision}${decision.reason ? ` · ${decision.reason}` : ""}`,
        ),
      ...frame.readings[id].details,
      `Default priority: ${SEGMENTS[id].priority}. ${SEGMENTS[id].variants}.`,
    ];
  }
}
