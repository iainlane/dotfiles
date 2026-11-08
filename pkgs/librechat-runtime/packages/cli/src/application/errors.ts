export class UsageError extends Error {
  readonly status = 2;
}

export class OperationalError extends Error {
  readonly status = 1;
}

export class CancelledError extends Error {
  readonly status = 130;

  constructor() {
    super("Cancelled. No changes were made.");
  }
}
