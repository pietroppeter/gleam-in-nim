#!/usr/bin/env escript
%% The oracle of tests/test_erlang_term_format.nim: real Erlang.
%% Each line of the input file is `<hex of the bytes we encoded> <tab> <the same term as Erlang source>`.
%% Erlang decodes the bytes with binary_to_term and compares with the term it parses from the source.
%% Prints `ok N`, or one `MISMATCH` line per term that differs.
main([File]) ->
    {ok, Data} = file:read_file(File),
    Lines = binary:split(Data, <<"\n">>, [global, trim_all]),
    Bad = lists:filter(fun(Line) -> not same(Line) end, Lines),
    case Bad of
        [] -> io:format("ok ~p~n", [length(Lines)]);
        _ -> [io:format("MISMATCH ~ts~n", [L]) || L <- Bad], halt(1)
    end.

same(Line) ->
    [Hex, Source] = binary:split(Line, <<"\t">>),
    Bytes = << <<(binary_to_integer(<<A, B>>, 16))>> || <<A, B>> <= Hex >>,
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(<<Source/binary, ".">>)),
    {ok, Expected} = erl_parse:parse_term(Tokens),
    try binary_to_term(Bytes) =:= Expected
    catch _:_ -> false
    end.
