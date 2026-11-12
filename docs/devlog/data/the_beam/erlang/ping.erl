-module(ping).
-export([main/0]).

%% Two processes, one message each way.
main() ->
    Me = self(),
    Pong = spawn(fun() ->
        receive
            {ping, From} ->
                io:format("pong process ~p got ping~n", [self()]),
                From ! pong
        end
    end),
    Pong ! {ping, Me},
    receive
        pong -> io:format("main process ~p got pong~n", [Me])
    after 1000 ->
        io:format("nobody answered~n")
    end.
