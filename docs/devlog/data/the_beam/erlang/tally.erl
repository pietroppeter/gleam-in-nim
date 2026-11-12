-module(tally).
-behaviour(gen_server).
-export([start_link/0, add/1, get/0, init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, tally}, ?MODULE, [], []).
add(N) -> gen_server:call(tally, {add, N}).
get() -> gen_server:call(tally, get).

init([]) -> {ok, 0}.
handle_call({add, N}, _From, Total) -> {reply, ok, Total + N};
handle_call(get, _From, Total) -> {reply, Total, Total}.
handle_cast(_Msg, Total) -> {noreply, Total}.
