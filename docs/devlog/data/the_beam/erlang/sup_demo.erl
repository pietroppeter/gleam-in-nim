-module(sup_demo).
-behaviour(supervisor).
-export([main/0, init/1]).

%% OTP: the same ideas, packaged. A supervisor restarts a gen_server that crashes.
init([]) ->
    Child = #{id => tally, start => {tally, start_link, []}},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Child]}}.

main() ->
    logger:set_primary_config(level, none),
    {ok, _Sup} = supervisor:start_link({local, demo_sup}, ?MODULE, []),
    tally:add(41),
    tally:add(1),
    io:format("tally is ~p in process ~p~n", [tally:get(), whereis(tally)]),
    catch tally:add(not_a_number),
    timer:sleep(50),
    io:format("tally is ~p in process ~p~n", [tally:get(), whereis(tally)]).
