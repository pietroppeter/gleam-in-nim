-module(mailbox).
-export([main/0]).

%% receive is selective: it takes the first message that matches a pattern,
%% and leaves the others in the mailbox, in order.
main() ->
    self() ! {letter, "first"},
    self() ! {parcel, "second"},
    self() ! {letter, "third"},
    receive {parcel, P} -> io:format("took the parcel: ~s~n", [P]) end,
    receive {letter, A} -> io:format("then a letter:   ~s~n", [A]) end,
    receive {letter, B} -> io:format("then a letter:   ~s~n", [B]) end.
