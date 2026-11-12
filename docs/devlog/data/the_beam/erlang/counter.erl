-module(counter).
-export([main/0, loop/1]).

%% An actor by hand: a recursive function whose argument is the state.
loop(Count) ->
    receive
        {increment, By} ->
            loop(Count + By);
        {get, From} ->
            From ! {count, Count},
            loop(Count);
        stop ->
            ok
    end.

main() ->
    Counter = spawn(counter, loop, [0]),
    Counter ! {increment, 2},
    Counter ! {increment, 40},
    Counter ! {get, self()},
    receive
        {count, N} -> io:format("counter says: ~p~n", [N])
    end,
    Counter ! stop.
