-module(crash).
-export([main/0]).

%% Failure is a message. A monitor turns the death of a process into data.
main() ->
    {Pid, Ref} = spawn_monitor(fun() ->
        receive {divide, A, B} -> io:format("~p~n", [A div B]) end
    end),
    Pid ! {divide, 1, 0},
    receive
        {'DOWN', Ref, process, Pid, {Reason, _Stack}} ->
            io:format("worker ~p died: ~p~n", [Pid, Reason]),
            io:format("the observer is fine, thanks for asking~n")
    end.
