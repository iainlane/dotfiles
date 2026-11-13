import { LayoutPages, PROFILE_LABELS } from "./layout-pages.ts";
import { REGIONS } from "#footer/configuration/settings.ts";
import { SettingsConflictError } from "#footer/configuration/settings-store.ts";
import type {
  CustomiserEnvironment,
  CustomiserMenu,
  CustomiserNavigation,
  CustomiserRow,
} from "./customiser-page.ts";
import { text } from "#footer/shared/text.ts";

function shortPath(path: string, home: string): string {
  return path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
}
class SavingPages {
  private readonly env: CustomiserEnvironment;
  private readonly navigation: CustomiserNavigation;
  constructor(env: CustomiserEnvironment, navigation: CustomiserNavigation) {
    this.env = env;
    this.navigation = navigation;
  }
  save(confirmed = false): void {
    const transaction = this.env.transaction;
    if (transaction.source.destination.kind === "session") {
      transaction.useForSession();
      return;
    }
    if (!confirmed && transaction.confirmationNeeded) {
      this.navigation.open(this.confirmation());
      return;
    }
    try {
      transaction.save(confirmed);
    } catch (error) {
      this.navigation.open(this.failure(error, confirmed));
    }
  }
  private information(id: string, label: string, value: string): CustomiserRow {
    return {
      id,
      label,
      description: value,
      intent: "open",
      run: () =>
        this.navigation.open({
          kind: "detail",
          title: label,
          lines: () => [value],
        }),
    };
  }
  source(): CustomiserMenu {
    return {
      kind: "menu",
      title: "Source & saving",
      rows: () => {
        const source = this.env.transaction.source;
        const path = shortPath(source.loaded.path, this.env.homeDirectory);
        let destination = "This session";
        if (source.destination.kind === "file") {
          destination = shortPath(
            source.destination.path,
            this.env.homeDirectory,
          );
        }
        if (source.destination.kind === "unavailable") {
          destination = source.destination.problem.message;
        }
        const fallback =
          source.base.source !== "file" &&
          source.loaded.path === source.base.path;
        const active = this.env.sessionApplied()
          ? "This session"
          : fallback
            ? "Built-in Rich"
            : path;
        const rows: CustomiserRow[] = [
          this.information("active", "Active source", active),
          this.information("destination", "Destination", destination),
          this.information(
            "base-profile",
            "Base profile",
            PROFILE_LABELS[this.env.transaction.document.preset ?? "rich"],
          ),
          {
            id: "precedence",
            label: "Settings precedence",
            intent: "open",
            run: () =>
              this.navigation.open({
                kind: "detail",
                title: "Settings precedence",
                lines: () => [
                  "Local preferences replace base appearance until reset.",
                  `Base: ${source.base.path}`,
                  `Local preferences: ${source.userPath}`,
                ],
              }),
          },
          {
            id: "json",
            label: "Draft JSON",
            intent: "open",
            run: () =>
              this.navigation.open({
                kind: "detail",
                title: "Draft JSON",
                lines: () =>
                  JSON.stringify(this.env.transaction.document, null, 2).split(
                    "\n",
                  ),
              }),
          },
          {
            id: "reset",
            label: "Reset to base settings",
            intent: "use",
            run: () => {
              this.env.transaction.resetToBase();
              this.navigation.root();
            },
          },
          {
            id: "reload",
            label: "Reload from disk…",
            intent: "reload",
            run: () => this.navigation.open(this.reload()),
          },
        ];
        if (source.loaded.diagnostic !== undefined) {
          rows.unshift({
            ...this.information(
              "diagnostic",
              "Configuration error",
              source.loaded.diagnostic,
            ),
            tint: "error",
          });
        }
        return rows;
      },
    };
  }
  private confirmation(): CustomiserMenu {
    const source = this.env.transaction.source;
    const destination = source.destination;
    let title = "Save user settings";
    let path = source.userPath;
    let description = "User settings override base settings until reset.";
    if (destination.kind === "file") {
      path = destination.path;
    }
    if (this.env.transaction.resetting) {
      title = "Reset to base settings";
      path = source.userPath;
      description = "Remove user settings and restore base appearance.";
    } else if (destination.kind === "file" && destination.repair) {
      title = "Repair settings";
      description = "Replace the invalid document with this draft.";
    }
    return {
      kind: "menu",
      title,
      selected: "save",
      rows: () => [
        this.information(
          "path",
          shortPath(path, this.env.homeDirectory),
          description,
        ),
        {
          id: "save",
          label: "Save & use",
          intent: "save",
          run: () => this.save(true),
        },
        {
          id: "back",
          label: "Back",
          intent: "open",
          run: () => this.navigation.back(),
        },
      ],
    };
  }
  private failure(error: unknown, confirmed: boolean): CustomiserMenu {
    const message =
      error instanceof Error
        ? text(error.message, 500)
        : "Cannot save footer settings";
    const conflict = error instanceof SettingsConflictError;
    return {
      kind: "menu",
      title: "Couldn't save",
      selected: conflict ? "review" : "retry",
      rows: () => {
        const rows: CustomiserRow[] = [
          {
            ...this.information("error", message, "Save error"),
            tint: "error",
          },
        ];
        if (conflict) {
          rows.push({
            id: "review",
            label: "Review disk changes…",
            intent: "open",
            run: () => this.navigation.open(this.reload()),
          });
        } else {
          rows.push({
            id: "retry",
            label: "Retry",
            intent: "retry",
            run: () => {
              this.navigation.accept();
              this.save(confirmed);
            },
          });
        }
        rows.push(
          {
            id: "session",
            label: "Use for this session",
            intent: "use",
            run: () => this.env.transaction.useForSession(),
          },
          {
            id: "back",
            label: "Back",
            intent: "open",
            run: () => this.navigation.back(),
          },
        );
        return rows;
      },
    };
  }
  private reload(): CustomiserMenu {
    return {
      kind: "menu",
      title: "Reload settings",
      selected: "back",
      rows: () => [
        {
          id: "reload",
          label: "Discard draft & reload",
          description: "Load the current settings from disk",
          intent: "reload",
          run: () => {
            this.env.reload();
            this.navigation.root();
          },
        },
        {
          id: "back",
          label: "Back",
          intent: "open",
          run: () => this.navigation.back(),
        },
      ],
    };
  }
}
export function createCustomiserRoot(
  env: CustomiserEnvironment,
  navigation: CustomiserNavigation,
): CustomiserMenu {
  const layout = new LayoutPages(env, navigation);
  const saving = new SavingPages(env, navigation);
  return {
    kind: "menu",
    title: "",
    rows: () => {
      const document = env.transaction.document;
      const profile = REGIONS.some((region) => document[region] !== undefined)
        ? "Custom"
        : PROFILE_LABELS[document.preset ?? "rich"];
      const persistent = env.transaction.source.destination.kind !== "session";
      return [
        {
          id: "profile",
          label: "Profile",
          description: profile,
          run: () => navigation.open(layout.profiles()),
        },
        {
          id: "widgets",
          label: "Widgets…",
          run: () => navigation.open(layout.widgets()),
        },
        {
          id: "separators",
          label: "Separators…",
          run: () => navigation.open(layout.separators()),
        },
        {
          id: "sources",
          label: "Extension symbols…",
          run: () => navigation.open(layout.sources()),
        },
        {
          id: "saving",
          label: "Source & saving…",
          run: () => navigation.open(saving.source()),
        },
        {
          id: "save",
          label: persistent ? "Save & use" : "Use for this session",
          intent: persistent ? "save" : "use",
          run: () => saving.save(),
        },
      ];
    },
  };
}
