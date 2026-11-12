-module(counter_demo).
-compile([no_auto_import, nowarn_ignored, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-export([main/0]).

-spec main() -> nil.
main() ->
    case counter:start() of
        {ok, C} ->
            gleam@erlang@process:send(C, {increment, 2}),
            gleam@erlang@process:send(C, {increment, 40}),
            N = gleam@erlang@process:call(C, 100, fun(_value) ->
                {get, _value}
            end),
            gleam_stdlib:println(<<"counter says: "/utf8, (erlang:integer_to_binary(N))/binary>>),
            gleam@erlang@process:send(C, stop);

        _value@1 ->
            erlang:error(#{
                gleam_error => let_assert,
                message => ~"Pattern match failed, no pattern matched the value.",
                file => ~"src/counter_demo.gleam",
                module => ~"counter_demo",
                function => ~"main",
                line => 7,
                value => _value@1,
                start => 102,
                'end' => 136,
                pattern_start => 113,
                pattern_end => 118
            })
    end.

