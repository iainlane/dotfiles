import { constants, createReadStream, createWriteStream } from "node:fs";
import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  rename,
  rm,
} from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { join } from "node:path";
import { Readable, Transform, type TransformCallback } from "node:stream";
import { pipeline } from "node:stream/promises";
import { z } from "zod";
import { writePrivateJson } from "./config.ts";
import type { Session } from "./sessions.ts";
import type { VmFiles } from "./vm-backend.ts";

interface VmFileOptions {
  directory: string;
  socketDirectory: string;
  uid: number;
  image: string;
  kernel: string;
  initrd: string;
  init: string;
  checkpointMaxBytes: number;

  stopExistingVm(socket: string): Promise<void>;
}

export class VmStorageIdentityError extends Error {
  constructor() {
    super("Invalid runtime identity for VM storage");

    this.name = "VmStorageIdentityError";
  }
}

export class VmSocketDirectoryError extends Error {
  constructor() {
    super(
      "The VM socket directory must be private, owned by this user and not a symlink",
    );

    this.name = "VmSocketDirectoryError";
  }
}

export class CheckpointLimitError extends Error {
  constructor() {
    super("Workspace checkpoint exceeds the configured byte limit");

    this.name = "CheckpointLimitError";
  }
}

const bootSchema = z.object({ init: z.string().startsWith("/nix/store/") });

const checkpointSchema = z.object({
  digest: z.string().regex(/^[a-f0-9]{64}$/u),
  bytes: z.number().int().positive(),
});

class CheckpointDigest extends Transform {
  readonly hash = createHash("sha256");

  bytes = 0;
  private readonly maximum: number;

  constructor(maximum: number) {
    super();

    this.maximum = maximum;
  }

  override _transform(
    chunk: unknown,
    _encoding: BufferEncoding,
    callback: TransformCallback,
  ): void {
    if (!Buffer.isBuffer(chunk)) {
      callback(new CheckpointLimitError());

      return;
    }

    this.bytes += chunk.length;

    if (this.bytes > this.maximum) {
      callback(new CheckpointLimitError());

      return;
    }

    this.hash.update(chunk);

    callback(null, chunk);
  }
}

export async function ensurePrivateSocketDirectory(
  directory: string,
  uid: number,
): Promise<void> {
  await mkdir(directory, { recursive: true, mode: 0o700 });

  const information = await lstat(directory);

  if (
    !information.isDirectory() ||
    information.isSymbolicLink() ||
    information.uid !== uid ||
    (information.mode & 0o077) !== 0
  ) {
    throw new VmSocketDirectoryError();
  }
}

export class FileVmStorage implements VmFiles {
  private readonly options: VmFileOptions;

  constructor(options: VmFileOptions) {
    this.options = options;
  }

  private directory(session: Session): string {
    if (!/^rt_[a-f0-9]{40}$/u.test(session.runtimeId)) {
      throw new VmStorageIdentityError();
    }

    return join(this.options.directory, session.runtimeId);
  }

  private async recover(session: Session): Promise<void> {
    this.directory(session);

    await ensurePrivateSocketDirectory(
      this.options.socketDirectory,
      this.options.uid,
    );

    const socketId = session.runtimeId.slice(3, 23);

    const monitor = join(this.options.socketDirectory, `${socketId}.qmp`);

    await this.options.stopExistingVm(monitor);

    await Promise.all(
      [monitor, join(this.options.socketDirectory, `${socketId}.http`)].map(
        async (file) => rm(file, { force: true }),
      ),
    );
  }

  async prepare(session: Session): ReturnType<VmFiles["prepare"]> {
    const directory = this.directory(session);

    await mkdir(directory, { recursive: true, mode: 0o700 });

    await this.recover(session);

    let boot: z.infer<typeof bootSchema>;

    try {
      const raw: unknown = JSON.parse(
        await readFile(join(directory, "boot.json"), "utf8"),
      );

      boot = bootSchema.parse(raw);
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !("code" in error) ||
        error.code !== "ENOENT"
      ) {
        throw error;
      }

      await Promise.all(
        [
          [this.options.image, "root.qcow2"],
          [this.options.kernel, "kernel"],
          [this.options.initrd, "initrd"],
        ].map(async ([source, name]) => {
          const target = join(directory, name ?? "");

          await copyFile(source ?? "", target, constants.COPYFILE_FICLONE);

          await chmod(target, 0o600);
        }),
      );

      boot = { init: this.options.init };

      await writePrivateJson(join(directory, "boot.json"), boot);
    }

    const socketId = session.runtimeId.slice(3, 23);

    return {
      disk: join(directory, "root.qcow2"),
      kernel: join(directory, "kernel"),
      initrd: join(directory, "initrd"),
      init: boot.init,
      controlSocket: join(this.options.socketDirectory, `${socketId}.http`),
      monitorSocket: join(this.options.socketDirectory, `${socketId}.qmp`),
    };
  }

  async saveCheckpoint(
    session: Session,
    body: ReadableStream<Uint8Array>,
  ): Promise<void> {
    const directory = this.directory(session);

    const temporary = join(directory, `checkpoint-${randomUUID()}.tmp`);

    const digest = new CheckpointDigest(this.options.checkpointMaxBytes);

    try {
      await pipeline(
        Readable.fromWeb(body),
        digest,
        createWriteStream(temporary, { flags: "wx", mode: 0o600 }),
      );

      const file = await open(temporary, "r+");

      try {
        await file.sync();
      } finally {
        await file.close();
      }

      const hash = digest.hash.digest("hex");

      await rename(temporary, join(directory, `checkpoint-${hash}.tar.gz`));

      await writePrivateJson(join(directory, "checkpoint.json"), {
        digest: hash,
        bytes: digest.bytes,
      });

      const archives = await readdir(directory);

      await Promise.all(
        archives
          .filter(
            (name) =>
              /^checkpoint-[a-f0-9]{64}\.tar\.gz$/u.test(name) &&
              name !== `checkpoint-${hash}.tar.gz`,
          )
          .map(async (name) => rm(join(directory, name))),
      );
    } finally {
      await rm(temporary, { force: true });
    }
  }

  async readCheckpoint(session: Session): Promise<ReadableStream<Uint8Array>> {
    const directory = this.directory(session);

    const raw: unknown = JSON.parse(
      await readFile(join(directory, "checkpoint.json"), "utf8"),
    );

    const checkpoint = checkpointSchema.parse(raw);

    return Readable.toWeb(
      createReadStream(
        join(directory, `checkpoint-${checkpoint.digest}.tar.gz`),
      ),
    );
  }

  async remove(session: Session): Promise<void> {
    await this.recover(session);

    await rm(this.directory(session), { recursive: true, force: true });
  }
}
