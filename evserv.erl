%% Event server
-module(evserv).
-compile(export_all).

-record(state, {events,    %% list of #event{} records
                clients}). %% list of Pids

-record(event, {name="",
                description="",
                pid,
                %add PID klienta, do którego potem będzie dodawać 
                timeout={{1970,1,1},{0,0,0}}}).

%%% User Interface

% Zmodifikować funkcję  - send to clients, zrobić tylko send to konkretny PID 


%  SERVER 
%Serwer akceptuje subskrybcje od klientów 
%Przekazuje powiadomienia z procesów zdarzeń dla każdego subskrybenta 
%Akceptuje wiadomości, które są dodawane do zdarzeń (i zaczyna procesy x,y,z) 
%Akceptuje wiadomości, które są usuwane i następnie zabija proces 
%Może zostac przerwany przez klienta 
%Można ponownie załadować z shella 

% CLIENT 
%Subskrybuje serwer zdarzeń i odbiera powiadomienia od serwera jako wiadomości. 
%Pyta/prosi serwer o dodanie zdarzenia ze wszystkimi szczegółami 
%Pyta/prosi serwer o anulowanie zdarzenia 
%Monituruje serwer (by wiedzieć czy ulegnie zniszczeniu/awarii) 
%Jeśli potrzebuje, to może zamknąć serwer 

%x,y and z 
%Reprezentują powiadomienie oczekujące na uruchomienie 
%Wysyłają wiadomości do serweru zdarzeń jeśli czas się skończy 
%Odbierają anulowane wiadomości i zabite 



% register -> tworzy proces ale z nazwą, 
% dzięki czemu można się odwoływać do nazwy a nie do PID 
start() ->
    register(?MODULE, Pid=spawn(?MODULE, init, [])),
    Pid.

start_link() ->
    register(?MODULE, Pid=spawn_link(?MODULE, init, [])),
    Pid.

terminate() ->
    ?MODULE ! shutdown.

init() ->
    % Inicjalizacja dwóch list -> events i clients 
    %% Loading events from a static file could be done here.
    %% You would need to pass an argument to init (maybe change the functions
    %% start/0 and start_link/0 to start/1 and start_link/1) telling where the
    %% resource to find the events is. Then load it from here.
    %% Another option is to just pass the event straight to the server
    %% through this function.
    loop(#state{events=orddict:new(),
                clients=orddict:new()}).

%Subskrybcja przez Klienta - Serwer, 

subscribe(Pid) ->
    Ref = erlang:monitor(process, whereis(?MODULE)),
    ?MODULE ! {self(), Ref, {subscribe, Pid}},
   %{shell, server@localhost} ! {{shell, server@localhost}, Ref, {subscribe, Pid}},
    receive
        {Ref, ok} ->
            {ok, Ref};
        {'DOWN', Ref, process, _Pid, Reason} ->
            {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

% Stworzenie eventy 

add_event(Name, Description, TimeOut) ->
    Ref = make_ref(),
    ?MODULE ! {self(), Ref, {add, Name, Description, TimeOut}},
    receive
        {Ref, Msg} -> Msg
    after 5000 ->
        {error, timeout}
    end.

add_event2(Name, Description, TimeOut) ->
    Ref = make_ref(),
    ?MODULE ! {self(), Ref, {add, Name, Description, TimeOut}},
    receive
        {Ref, {error, Reason}} -> erlang:error(Reason);
        {Ref, Msg} -> Msg
    after 5000 ->
        {error, timeout}
    end.

cancel(Name) ->
    Ref = make_ref(),
    ?MODULE ! {self(), Ref, {cancel, Name}},
    receive
        {Ref, ok} -> ok
    after 5000 ->
        {error, timeout}
    end.

listen(Delay) ->
    receive
        M = {done, _Name, _Description} ->
            [M | listen(0)]
    after Delay*1000 ->
        []
    end.

%%% The Server itself

loop(S=#state{}) ->
    receive
                % Początek komunukacji Klient <---> Serwer 
    %--------------------------------
        {Pid, MsgRef, {subscribe, Client}} ->
            Ref = erlang:monitor(process, Client), %monitorowanie 
            NewClients = orddict:store(Ref, Client, S#state.clients), % dodanie klienta, do listy klientów, 
                                                                    % a dokładnie Pid Klienta do listy gdzie są PID innych klientów 
            Pid ! {MsgRef, ok}, % wysłanie komunikatu do klienta 
            loop(S#state{clients=NewClients});

            % DODAWANIE % 
        {Pid, MsgRef, {add, Name, Description, TimeOut}} -> % dodanie wydarzenia przez klienta, czyli mamy 
            case valid_datetime(TimeOut) of             % czyli Pid klienta, nazwa wydarzenia, opis oraz Czas 
                true ->
                    EventPid = event:start_link(Name, TimeOut), % połaczenie Nazwy wydarzenia z czasem 
                    NewEvents = orddict:store(Name, 
                                              #event{name=Name,
                                                     description=Description,
                                                     pid=EventPid,
                                                     timeout=TimeOut},
                                              S#state.events),
                    Pid ! {MsgRef, ok},
                    loop(S#state{events=NewEvents});
                false ->
                    Pid ! {MsgRef, {error, bad_timeout}}, % informacja o błędzie, a nie wywalenie się aplikacji 
                    loop(S)
            end;
        % USUWANIE % 
        {Pid, MsgRef, {cancel, Name}} ->
            Events = case orddict:find(Name, S#state.events) of % sprawdzanie czy jest to wydarzenie w liście 
                         {ok, E} ->
                             event:cancel(E#event.pid),
                             orddict:erase(Name, S#state.events);
                         error ->
                             S#state.events
                     end,
            Pid ! {MsgRef, ok},
            loop(S#state{events=Events});
            % Koniec komunukacji Klient <---> Serwer 
    %--------------------------------
        % Komunikacja pomiędzy Serwerem a Wydarzeniami/Agentami 

        % Informacja od Agenta, ze wydarzenie się odbyło, czyli czas się zakończył 
        {done, Name} ->
            case orddict:find(Name, S#state.events) of
                {ok, E} ->
                    % Wykoannie wydarzenia -> wysłanie komunikatu 
                    
                    send_to_clients({done, E#event.name, E#event.description},
                                    S#state.clients),
                    NewEvents = orddict:erase(Name, S#state.events),
                    loop(S#state{events=NewEvents});
                error ->
                    %% This may happen if we cancel an event and
                    %% it fires at the same time
                    loop(S)
            end;
        % Zabicie 
        shutdown ->
            exit(shutdown);
        {'DOWN', Ref, process, _Pid, _Reason} -> % Klieny "zmarł"
            loop(S#state{clients=orddict:erase(Ref, S#state.clients)});
        code_change ->
            ?MODULE:loop(S);
        {Pid, debug} -> %% used as a hack to let me do some unit testing
            Pid ! S,
            loop(S);
        Unknown ->
            io:format("Unknown message: ~p~n",[Unknown]),
            loop(S)
    end.

% Wysyłąnie komunikatów do klientów 
%%% Internal Functions
send_to_clients(Msg, ClientDict) ->
    orddict:map(fun(_Ref, Pid) -> Pid ! Msg end, ClientDict).

% Walidacja daty, by przyjmowanie eventów było w dobrej dacie

valid_datetime({Date,Time}) ->
    try
        calendar:valid_date(Date) andalso valid_time(Time)
    catch
        error:function_clause -> %% not in {{Y,M,D},{H,Min,S}} format
            false
    end;
valid_datetime(_) ->
    false.

%% calendar has valid_date, but nothing for days.
%% This function is based on its interface.
%% Ugly, but ugh.
valid_time({H,M,S}) -> valid_time(H,M,S).

valid_time(H,M,S) when H >= 0, H < 24,
                       M >= 0, M < 60,
                       S >= 0, S < 60 -> true;
valid_time(_,_,_) -> false.