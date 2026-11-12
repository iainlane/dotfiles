export function isReply(value: unknown): value is (data: unknown) => void {
  return typeof value === "function";
}
