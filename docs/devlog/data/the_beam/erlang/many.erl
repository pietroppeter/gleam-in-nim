-module(many).
-export([main/0]).

%% How cheap is a process? Spawn a hundred thousand and ask.
main() ->
    N = 100000,
    Before = erlang:memory(processes),
    {Micros, Pids} = timer:tc(fun() ->
        [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, N)]
    end),
    After = erlang:memory(processes),
    io:format("spawned ~p processes in ~p ms~n", [N, Micros div 1000]),
    io:format("about ~p bytes each~n", [(After - Before) div N]),
    io:format("alive right now: ~p~n", [erlang:system_info(process_count)]),
    [P ! stop || P <- Pids],
    ok.
