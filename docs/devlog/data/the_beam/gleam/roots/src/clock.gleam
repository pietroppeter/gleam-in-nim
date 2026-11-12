//// Externals: borrowing functions from the host platform.

/// One function, two targets, two foreign implementations.
@external(erlang, "os", "system_time")
@external(javascript, "./clock_ffi.mjs", "now")
pub fn now() -> Int

/// An external for one target only, with a Gleam body as the fallback
/// for every other target.
@external(erlang, "erlang", "unique_integer")
pub fn ticket() -> Int {
  42
}
