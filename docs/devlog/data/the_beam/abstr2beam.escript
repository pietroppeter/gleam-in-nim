#!/usr/bin/env escript
%% Compile what `gleam compile-package` leaves on disk into .beam files:
%% .abstr files (Erlang abstract forms in external term format) and .erl files (FFI).
%% usage: abstr2beam.escript <ebin-dir> <file>...
main([Out | Files]) ->
    ok = filelib:ensure_dir(filename:join(Out, "x")),
    Results = [compile(Out, F) || F <- Files],
    case [R || R <- Results, R =/= ok] of
        [] -> io:format("compiled ~p modules~n", [length(Files)]);
        Bad -> io:format("~P~n", [Bad, 12]), halt(1)
    end.

is_doc({attribute, _, doc, _}) -> true;
is_doc({attribute, _, moduledoc, _}) -> true;
is_doc(_) -> false.

compile(Out, File) ->
    case filename:extension(File) of
        ".abstr" ->
            {ok, Bin} = file:read_file(File),
            %% -doc and -moduledoc are OTP 27 attributes. An older OTP rejects them
            %% after a function, so they are dropped here. Nothing else changes.
            Forms = [F || F <- binary_to_term(Bin), not is_doc(F)],
            case compile:forms(Forms, [return_errors]) of
                {ok, Mod, Beam} ->
                    file:write_file(filename:join(Out, atom_to_list(Mod) ++ ".beam"), Beam);
                Error -> {File, Error}
            end;
        ".erl" ->
            case compile:file(File, [return_errors, {outdir, Out}]) of
                {ok, _} -> ok;
                Error -> {File, Error}
            end
    end.
