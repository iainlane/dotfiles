import { isAbsolute, relative, sep } from "node:path";
import {
  resolveToCwd,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Check } from "typebox/value";

const pathSchema = Type.Object({ path: Type.String() });
const legacyPathSchema = Type.Object({ file_path: Type.String() });

function toolPath(args: unknown): string | undefined {
  if (Check(pathSchema, args)) {
    return args.path;
  }
  if (Check(legacyPathSchema, args)) {
    return args.file_path;
  }
  return undefined;
}

function isPlanPath(args: unknown, directory: string, cwd: string): boolean {
  const path = toolPath(args);
  if (path === undefined) {
    return false;
  }
  const local = relative(directory, resolveToCwd(path, cwd));
  return (
    local !== "" &&
    local !== ".." &&
    !local.startsWith(`..${sep}`) &&
    !isAbsolute(local)
  );
}

export function registerPlanHeadings(
  pi: Pick<ExtensionAPI, "registerToolRenderer">,
  directory: string,
): void {
  const plans = resolveToCwd(directory, process.cwd());
  pi.registerToolRenderer((toolName, next) => {
    const delegated = next();
    if (toolName !== "write" && toolName !== "edit") {
      return delegated;
    }
    return {
      ...delegated,
      resolveCallLabel: (args, context) =>
        isPlanPath(args, plans, context.cwd)
          ? "Updated plan"
          : delegated?.resolveCallLabel?.(args, context),
    };
  });
}
