-module(counter).
-compile([no_auto_import, nowarn_ignored, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-export([start/0]).
-export_type([message/0]).
-moduledoc(~" A counter as an actor: one process, one mailbox, one piece of state.").

-type message() :: {increment, integer()} | {get, gleam@erlang@process:subject(integer())} | stop.

-spec handle(integer(), message()) -> gleam@otp@actor:next(integer(), message()).
handle(Count, Message) ->
    case Message of
        {increment, By} ->
            gleam@otp@actor:continue(Count + By);

        {get, Reply_to} ->
            gleam@erlang@process:send(Reply_to, Count),
            gleam@otp@actor:continue(Count);

        stop ->
            gleam@otp@actor:stop()
    end.

-spec result_map_data({ok, gleam@otp@actor:started(gleam@erlang@process:subject(message()))} | {error, gleam@otp@actor:start_error()}) -> {ok, gleam@erlang@process:subject(message())} | {error, gleam@otp@actor:start_error()}.
result_map_data(R) ->
    case R of
        {ok, Started} ->
            {ok, erlang:element(3, Started)};

        {error, E} ->
            {error, E}
    end.

-spec start() -> {ok, gleam@erlang@process:subject(message())} | {error, gleam@otp@actor:start_error()}.
start() ->
    _pipe = gleam@otp@actor:new(0),
    _pipe@1 = gleam@otp@actor:on_message(_pipe, fun handle/2),
    _pipe@2 = gleam@otp@actor:start(_pipe@1),
    result_map_data(_pipe@2).

