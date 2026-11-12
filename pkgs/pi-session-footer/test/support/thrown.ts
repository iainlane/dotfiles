export class NothingThrownError extends Error {
  constructor() {
    super("Expected the action to throw");
    this.name = "NothingThrownError";
  }
}

/**
 * Returns the value that `action` throws, so a test can compare the whole
 * error, including its class and fields, with `toStrictEqual`.
 */
export function thrown(action: () => unknown): unknown {
  try {
    action();
  } catch (error) {
    return error;
  }
  throw new NothingThrownError();
}
