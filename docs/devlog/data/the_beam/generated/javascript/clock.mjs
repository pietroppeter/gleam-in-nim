import { now } from "./clock_ffi.mjs";

export { now };

/**
 * An external for one target only, with a Gleam body as the fallback
 * for every other target.
 */
export function ticket() {
  return 42;
}
