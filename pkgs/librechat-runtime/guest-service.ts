import type { Command, ManagedProcess } from "./processes.ts";

interface GuestServiceDependencies {
  start(command: Command): Promise<ManagedProcess>;

  stop(child: ManagedProcess): Promise<void>;
}

export class GuestServiceProcess {
  private readonly dependencies: GuestServiceDependencies;
  private child: ManagedProcess | undefined;
  private ready = false;
  private startup: Promise<ManagedProcess> | undefined;

  constructor(dependencies: GuestServiceDependencies) {
    this.dependencies = dependencies;
  }

  isReady(): boolean {
    return this.ready && this.child?.running() === true;
  }

  async start(
    command: Command,
    initialise: (child: ManagedProcess) => Promise<void>,
  ): Promise<ManagedProcess> {
    if (this.startup !== undefined) {
      return await this.startup;
    }

    if (this.isReady() && this.child !== undefined) {
      return this.child;
    }

    const startup = this.launch(command, initialise);

    this.startup = startup;

    try {
      return await startup;
    } finally {
      this.startup = undefined;
    }
  }

  private async launch(
    command: Command,
    initialise: (child: ManagedProcess) => Promise<void>,
  ): Promise<ManagedProcess> {
    await this.stop();

    this.child = await this.dependencies.start(command);

    try {
      await initialise(this.child);

      this.ready = true;

      return this.child;
    } catch (error) {
      await this.stop();

      throw error;
    }
  }

  async stop(): Promise<void> {
    this.ready = false;

    if (this.child === undefined) {
      return;
    }

    await this.dependencies.stop(this.child);

    this.child = undefined;
  }
}
