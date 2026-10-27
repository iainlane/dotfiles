import type { Command } from "./processes.ts";

interface WorkspaceIdentity {
  uid: number;
  gid: number;
}

interface WorkspaceTrustOptions extends WorkspaceIdentity {
  mkdir: string;
  certutil: string;
}

interface WorkspaceTrustDependencies {
  inspect(): Promise<WorkspaceIdentity & { directory: boolean }>;

  databaseExists(): Promise<boolean>;

  run(command: Command): Promise<string>;
}

export class GuestWorkspaceIdentityError extends Error {
  constructor() {
    super(
      "The guest workspace must be a directory owned by the configured workspace user and group",
    );

    this.name = "GuestWorkspaceIdentityError";
  }
}

export class GuestWorkspaceTrust {
  private readonly options: WorkspaceTrustOptions;
  private readonly dependencies: WorkspaceTrustDependencies;

  constructor(
    options: WorkspaceTrustOptions,
    dependencies: WorkspaceTrustDependencies,
  ) {
    this.options = options;

    this.dependencies = dependencies;
  }

  async prepare(): Promise<WorkspaceIdentity> {
    const workspace = await this.dependencies.inspect();

    if (
      !workspace.directory ||
      workspace.uid !== this.options.uid ||
      workspace.gid !== this.options.gid
    ) {
      throw new GuestWorkspaceIdentityError();
    }

    const identity = { uid: this.options.uid, gid: this.options.gid };

    const trustDirectory = "/tmp/sandbox/session/.pki";

    await this.dependencies.run({
      executable: this.options.mkdir,
      args: ["-p", "-m", "700", "--", `${trustDirectory}/nssdb`],
      ...identity,
    });

    if (!(await this.dependencies.databaseExists())) {
      await this.dependencies.run({
        executable: this.options.certutil,
        args: ["-N", "--empty-password", "-d", `sql:${trustDirectory}/nssdb`],
        ...identity,
      });
    }

    await this.dependencies.run({
      executable: this.options.certutil,
      args: [
        "-A",
        "-n",
        "LibreChat egress CA",
        "-t",
        "C,,",
        "-i",
        "/run/librechat-guest/iron-ca.crt",
        "-d",
        `sql:${trustDirectory}/nssdb`,
      ],
      ...identity,
    });

    return identity;
  }
}
