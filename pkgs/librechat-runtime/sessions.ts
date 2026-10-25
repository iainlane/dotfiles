import {
  SessionOwnerError,
  SessionBusyError,
  SessionClosingError,
  WorkspaceRecoveryError,
  WorkspaceQuarantinedError,
  ConversationPrincipalError,
  ConversationIdError,
  RuntimeNotRegisteredError,
  QuarantineTargetError,
} from "./errors.ts";
import { z } from "zod";
import { runtimeIdentity } from "./identity.ts";

const runtimeIdSchema = z.string().regex(/^rt_[a-f0-9]{40}$/u);

const sessionSchema = z.object({
  runtimeId: runtimeIdSchema,
  conversationId: z.uuid().nullable(),
  userId: z.string().regex(/^[a-f0-9]{24}$/u),
  generation: z.number().int().positive(),
  lastUsed: z.number().nonnegative(),
  checkpoint: z.boolean(),
  expired: z.boolean(),
  resetReason: z.string(),
  quarantine: z.string().nullable().default(null),
});

export type Session = z.infer<typeof sessionSchema>;

export interface Guest {
  socket: string;
  bootId: string;
}

export interface GuestBackend {
  start(
    session: Session,
    restore: boolean,
    signal?: AbortSignal,
  ): Promise<Guest>;

  checkpoint(session: Session, guest: Guest): Promise<void>;

  stop(session: Session, guest: Guest): Promise<void>;

  remove(session: Session): Promise<void>;
}

interface SessionEntry {
  session: Session;
  guest?: Guest;
  leases: number;
}

export interface SessionStore {
  load(runtimeId: string): Promise<unknown>;

  save(session: Session): Promise<void>;

  list(): Promise<string[]>;
}

interface SessionManagerOptions {
  store: SessionStore;
  userId: string;
  idleMs: number;
  retentionMs: number;
  backend: GuestBackend;
  now?: () => number;
}

export interface SessionLease {
  session: Session;
  guest: Guest;

  release(): Promise<void>;
}

export class SessionManager {
  private readonly options: SessionManagerOptions;
  private readonly entries = new Map<string, SessionEntry>();
  private readonly locks = new Map<string, Promise<unknown>>();
  private readonly now: () => number;
  private closing = false;

  constructor(options: SessionManagerOptions) {
    this.options = options;

    this.now = options.now ?? Date.now;
  }

  private async locked<T>(id: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.locks.get(id) ?? Promise.resolve();

    const current = previous.catch(() => null).then(operation);

    this.locks.set(id, current);

    try {
      return await current;
    } finally {
      if (this.locks.get(id) === current) {
        this.locks.delete(id);
      }
    }
  }

  private async save(session: Session): Promise<void> {
    await this.options.store.save(session);
  }

  private async load(id: string): Promise<SessionEntry | undefined> {
    const cached = this.entries.get(id);

    if (cached !== undefined) {
      return cached;
    }

    const raw = await this.options.store.load(id);

    if (raw === undefined) {
      return undefined;
    }

    const session = sessionSchema.parse(raw);

    if (
      session.userId !== this.options.userId ||
      session.runtimeId !== id ||
      (session.conversationId !== null &&
        runtimeIdentity(session.userId, session.conversationId) !== id)
    ) {
      throw new SessionOwnerError();
    }

    const entry: SessionEntry = { session, leases: 0 };

    this.entries.set(id, entry);

    return entry;
  }

  private async ready(
    entry: SessionEntry,
    signal?: AbortSignal,
  ): Promise<Guest> {
    signal?.throwIfAborted();

    if (entry.session.quarantine !== null) {
      throw new WorkspaceQuarantinedError();
    }

    if (entry.guest !== undefined) {
      return entry.guest;
    }

    const guest = await this.options.backend.start(
      entry.session,
      entry.session.checkpoint,
      signal,
    );

    if (signal?.aborted === true) {
      await this.options.backend.stop(entry.session, guest);

      signal.throwIfAborted();
    }

    entry.guest = guest;

    return guest;
  }

  async activate(userId: string, conversationId: string): Promise<Session> {
    if (this.closing) {
      throw new SessionClosingError();
    }

    if (userId !== this.options.userId) {
      throw new ConversationPrincipalError();
    }

    if (!z.uuid().safeParse(conversationId).success) {
      throw new ConversationIdError();
    }

    const id = runtimeIdentity(userId, conversationId);

    return await this.locked(id, async () => {
      if (this.closing) {
        throw new SessionClosingError();
      }

      let entry = await this.load(id);

      if (entry === undefined) {
        entry = {
          leases: 0,
          session: {
            runtimeId: id,
            conversationId,
            userId,
            generation: 1,
            lastUsed: this.now(),
            checkpoint: false,
            expired: false,
            resetReason: "A new conversation workspace was created.",
            quarantine: null,
          },
        };

        this.entries.set(id, entry);
      }

      await this.expire(entry);

      entry.session.conversationId = conversationId;

      entry.session.expired = false;

      entry.session.lastUsed = this.now();

      await this.save(entry.session);

      await this.ready(entry);

      return { ...entry.session };
    });
  }

  async acquire(runtimeId: string): Promise<SessionLease> {
    return await this.leaseRuntime(runtimeId, false);
  }

  async acquireCodeRuntime(
    runtimeId: string,
    signal?: AbortSignal,
  ): Promise<SessionLease> {
    signal?.throwIfAborted();

    if (this.closing) {
      throw new SessionClosingError();
    }

    runtimeIdSchema.parse(runtimeId);

    await this.locked(runtimeId, async () => {
      signal?.throwIfAborted();

      let entry = await this.load(runtimeId);

      signal?.throwIfAborted();

      if (entry === undefined) {
        entry = {
          leases: 0,
          session: {
            runtimeId,
            conversationId: null,
            userId: this.options.userId,
            generation: 1,
            lastUsed: this.now(),
            checkpoint: false,
            expired: false,
            resetReason:
              "A new conversation workspace was created during Code Interpreter prewarming.",
            quarantine: null,
          },
        };

        this.entries.set(runtimeId, entry);
      }

      await this.expire(entry);

      entry.session.expired = false;

      entry.session.lastUsed = this.now();

      await this.save(entry.session);
    });

    return await this.leaseRuntime(runtimeId, true, signal);
  }

  private async leaseRuntime(
    runtimeId: string,
    allowUnbound: boolean,
    signal?: AbortSignal,
  ): Promise<SessionLease> {
    runtimeIdSchema.parse(runtimeId);

    return await this.locked(runtimeId, async () => {
      signal?.throwIfAborted();

      if (this.closing) {
        throw new SessionClosingError();
      }

      const entry = await this.load(runtimeId);

      if (
        entry === undefined ||
        entry.session.expired ||
        (!allowUnbound && entry.session.conversationId === null)
      ) {
        throw new RuntimeNotRegisteredError();
      }

      const guest = await this.ready(entry, signal);

      signal?.throwIfAborted();

      entry.session.lastUsed = this.now();

      await this.save(entry.session);

      entry.leases += 1;

      if (signal?.aborted === true) {
        entry.leases -= 1;

        signal.throwIfAborted();
      }

      let released = false;

      return {
        session: { ...entry.session },
        guest,
        release: async () => {
          await this.locked(runtimeId, async () => {
            if (released) {
              return;
            }

            released = true;
            entry.leases -= 1;

            entry.session.lastUsed = this.now();

            await this.save(entry.session);
          });
        },
      };
    });
  }

  private async expire(entry: SessionEntry): Promise<void> {
    if (
      entry.session.expired ||
      entry.leases > 0 ||
      this.now() - entry.session.lastUsed < this.options.retentionMs
    ) {
      return;
    }

    if (entry.guest !== undefined) {
      await this.options.backend.stop(entry.session, entry.guest);
      delete entry.guest;
    }

    await this.options.backend.remove(entry.session);
    entry.session.generation += 1;

    entry.session.checkpoint = false;

    entry.session.expired = true;

    entry.session.quarantine = null;

    entry.session.resetReason =
      "The previous workspace expired and was deleted, including unpushed work.";
    await this.save(entry.session);
  }

  async sweep(): Promise<void> {
    const names = await this.options.store.list();

    await Promise.all(
      names
        .filter((name) => runtimeIdSchema.safeParse(name).success)
        .map(async (id) => {
          await this.locked(id, async () => {
            const entry = await this.load(id);

            if (entry === undefined || entry.leases > 0) {
              return;
            }

            await this.expire(entry);

            if (
              entry.guest === undefined ||
              this.now() - entry.session.lastUsed < this.options.idleMs
            ) {
              return;
            }

            await this.suspend(entry);
          });
        }),
    );
  }

  private async suspend(entry: SessionEntry): Promise<void> {
    if (entry.guest === undefined) {
      return;
    }

    try {
      await this.options.backend.checkpoint(entry.session, entry.guest);
    } catch (error) {
      if (error instanceof WorkspaceRecoveryError) {
        entry.session.quarantine = error.name;

        await this.save(entry.session);

        await this.options.backend.stop(entry.session, entry.guest);
        delete entry.guest;
      }

      throw error;
    }

    entry.session.checkpoint = true;

    await this.save(entry.session);

    await this.options.backend.stop(entry.session, entry.guest);
    delete entry.guest;
  }

  async shutdown(): Promise<void> {
    this.closing = true;

    await Promise.allSettled(this.locks.values());

    if ([...this.entries.values()].some((entry) => entry.leases > 0)) {
      throw new SessionBusyError();
    }

    await Promise.all(
      [...this.entries].map(async ([id, entry]) =>
        this.locked(id, async () => this.suspend(entry)),
      ),
    );
  }

  async reset(runtimeId: string): Promise<void> {
    runtimeIdSchema.parse(runtimeId);

    await this.locked(runtimeId, async () => {
      const entry = await this.load(runtimeId);

      if (entry === undefined) {
        throw new RuntimeNotRegisteredError();
      }

      if (entry.leases > 0) {
        throw new SessionBusyError();
      }

      if (entry.guest !== undefined) {
        await this.options.backend.stop(entry.session, entry.guest);
        delete entry.guest;
      }

      await this.options.backend.remove(entry.session);
      entry.session.generation += 1;

      entry.session.checkpoint = false;

      entry.session.quarantine = null;

      entry.session.lastUsed = this.now();

      entry.session.resetReason =
        "The workspace was explicitly reset and unpushed work was discarded.";
      await this.save(entry.session);
    });
  }

  async quarantine(runtimeId: string, reason: string): Promise<void> {
    runtimeIdSchema.parse(runtimeId);

    await this.locked(runtimeId, async () => {
      const entry = await this.load(runtimeId);

      if (entry === undefined) {
        throw new QuarantineTargetError();
      }

      entry.session.quarantine = reason;

      await this.save(entry.session);

      if (entry.guest !== undefined) {
        await this.options.backend.stop(entry.session, entry.guest);
        delete entry.guest;
      }
    });
  }
}
