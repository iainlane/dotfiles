import { readFile } from "node:fs/promises";

export interface FrontendFiles {
  readText(path: string): Promise<string>;
  readBytes(path: string): Promise<Buffer>;
}

export class NodeFrontendFiles implements FrontendFiles {
  async readText(path: string): Promise<string> {
    return await readFile(path, "utf8");
  }

  async readBytes(path: string): Promise<Buffer> {
    return await readFile(path);
  }
}
