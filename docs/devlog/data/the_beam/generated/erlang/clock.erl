-module(clock).
-compile([no_auto_import, nowarn_ignored, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-export([now/0, ticket/0]).
-moduledoc(~" Externals: borrowing functions from the host platform.").

-spec now() -> integer().
-doc(~" One function, two targets, two foreign implementations.").
now() ->
    os:system_time().

-spec ticket() -> integer().
-doc(~" An external for one target only, with a Gleam body as the fallback
 for every other target.").
ticket() ->
    erlang:unique_integer().

