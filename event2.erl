-module(event2).
-export([start/3, start_link/3, cancel/1]).
-export([init/4, loop/1]).
-record(state2, {server,
                name="",
                to_go=0, 
                ref =""}).

% X Y and Z -> Powiadomienia/Agenci/Alarmy 

% DataTime -> np.{{2019,11,21},{19,1,58}}

%%% Public interface
% Tworzenie procesów, zdarzeń, przy użyciu funkcji Init, która uruchamia loop 
start(EventName, DateTime, Ref) ->
    spawn(?MODULE, init, [self(), EventName, DateTime, Ref]).

start_link(EventName, DateTime, Ref) ->
    spawn_link(?MODULE, init, [self(), EventName, DateTime, Ref]).


%usuwanie zdarzenia po PiD 
cancel(Pid) ->
    %% Monitor in case the process is already dead
    Ref = erlang:monitor(process, Pid),
    Pid ! {self(), Ref, cancel},
    receive
        {Ref, ok} ->
            erlang:demonitor(Ref, [flush]),
            ok;
        {'DOWN', Ref, process, Pid, _Reason} ->
            ok
    end.

%%% Event's innards
% Inicjacja Agentu, konkretnego wydarzenia/eventu z datą, infrmującą kiedy on jest 
init(Server, EventName, DateTime, Ref) ->
    loop(#state2{server=Server,
                name=EventName,
                to_go=time_to_go(DateTime), ref=Ref}).

%% Loop uses a list for times in order to go around the ~49 days limit
%% on timeouts.
%  State -> limit czasu, nazwa eventu,  -> w celu wysłania komunikatu {done, Id}
% Stan state ma serwer, ma nazwkę o zmienną to_go 
% Timeout -> in seconds 
loop(S = #state2{server=Server, to_go=[T|Next], ref=Ref}) ->
    receive
        {Server, Ref, cancel} ->
            Server ! {Ref, ok}
    after T*1000 ->
        if Next =:= [] ->
            Server ! {done, S#state2.name, Ref};
           Next =/= [] ->
            loop(S#state2{to_go=Next})
        end
    end.



% Obliczanie czasu ile jest od stworzenia powiadomienia do wysłania powiadomienia, 
% podawany w sekundach znormalizowanych 
%%% private functions
%({{Year, Month, Day}, {Hour, Minute, Second}}).
time_to_go(TimeOut={{_,_,_}, {_,_,_}}) ->
    Now = calendar:local_time(),
    ToGo = calendar:datetime_to_gregorian_seconds(TimeOut) -
           calendar:datetime_to_gregorian_seconds(Now),
    Secs = if ToGo > 0  -> ToGo;
              ToGo =< 0 -> 0
           end,
    normalize(Secs).

%% Because Erlang is limited to about 49 days (49*24*60*60*1000) in
%% milliseconds, the following function is used
normalize(N) ->
    Limit = 49*24*60*60,
    [N rem Limit | lists:duplicate(N div Limit, Limit)].