%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_gw_router).
-behaviour(gen_server).

-export([start_link/0]).
-export([register/3, status/2, uplinks/1, downlink/5, downlink_error/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").
-include("lorawan.hrl").

-record(state, {pulladdr, recent, beacon_timer, downlink_timer}).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

register(MAC, Process, Target) ->
    gen_server:cast({global, ?MODULE}, {register, MAC, Process, Target}).

status(MAC, S) ->
    gen_server:cast({global, ?MODULE}, {status, MAC, S}).

uplinks(PkList) ->
    gen_server:cast({global, ?MODULE}, {uplinks, PkList}).
    

downlink(Req, MAC, DevAddr, TxQ, PHYPayload) ->
    {atomic, ok} = mnesia:transaction(
        fun() ->
            [Gateway] = mnesia:read(gateways, MAC, read),
            Stats =
                case mnesia:read(gateway_stats, MAC, write) of
                    [S] -> S;
                    [] -> #gateway_stats{mac=MAC, dwell=[], delays=[]}
                end,
            downlink0(Req, Gateway, Stats, DevAddr, TxQ, PHYPayload)
        end),
    ok.

downlink0(Req, Gateway, Stats, DevAddr, TxQ, PHYPayload) ->
    Power = limit_power(Gateway, lorawan_mac_region:eirp_limits(TxQ#txq.region)),
    Time = lorawan_mac_region:tx_time(byte_size(PHYPayload), TxQ),
    Dwell0 =
        case Stats#gateway_stats.dwell of
            undefined -> [];
            List -> List
        end,
    % summarize transmissions in the past hour
    Now = lorawan_utils:precise_universal_time(),
    HourAgo = lorawan_utils:apply_offset(Now, {-1,0,0}),
    Relevant = lists:filter(fun({ITime, _}) -> ITime > HourAgo end, Dwell0),
    Sum =
        lists:foldl(
            fun({_, {_, Duration, _}}, Acc) ->
                Acc + Duration
            end, 0, Relevant),
    Dwell =
        if
            length(HourAgo) >= 20 -> HourAgo;
            true -> lists:sublist(Dwell0, 20)
        end,
    ok = mnesia:write(gateway_stats,
        Stats#gateway_stats{dwell=[{Now, {TxQ#txq.freq, Time, Sum+Time}} | Dwell]}, write),
    gen_server:cast({global, ?MODULE}, {downlink, Req, Gateway#gateway.mac, DevAddr,
        TxQ#txq{powe=Power}, Gateway#gateway.tx_rfch, PHYPayload}).

limit_power(Gateway, {EIRPdef, EIRPmax}) ->
    Power = value_or_default(Gateway#gateway.tx_powe, EIRPdef),
    Gain = value_or_default(Gateway#gateway.ant_gain, 0),
    erlang:min(Power, EIRPmax-Gain).

downlink_error(MAC, Opaque, Error) ->
    gen_server:cast({global, ?MODULE}, {downlink_error, MAC, Opaque, Error}).

value_or_default(Num, _Def) when is_number(Num) -> Num;
value_or_default(_Num, Def) -> Def.

init([]) ->
    lager:debug("[beacon] init"),
    BeaconTimer = erlang:send_after(10000, self(), beacon),
    Downlink_timer = erlang:send_after(20000,self(), pending_downlink),
    {ok, #state{pulladdr=dict:new(), recent=dict:new(), beacon_timer = BeaconTimer, downlink_timer = Downlink_timer}}.

handle_call(_Request, _From, State) ->
    {stop, {error, unknownmsg}, State}.

handle_cast({register, MAC, Process, {Host, Port, _}=Target}, #state{pulladdr=Dict}=State) ->
    case dict:find(MAC, Dict) of
        {ok, {Process, Target}} ->
            {noreply, State};
        _Else ->
            lorawan_utils:throw_info({gateway, MAC}, {connected, {Host, Port}}),
            Dict2 = dict:store(MAC, {Process, Target}, Dict),
            {noreply, State#state{pulladdr=Dict2}}
    end;

handle_cast({status, MAC, S}, State) ->
    case lorawan_mac:process_status(MAC, S) of
        ok ->
            ok;
        {error, {Object, Error}} ->
            lorawan_utils:throw_error(Object, Error)
    end,
    {noreply, State};

handle_cast({uplinks, PkList}, #state{recent=Recent}=State) ->
    % due to reflections the gateways may have received the same frame twice
    % reflected frames received by the same gateway are ignored
    Unique = remove_duplicates(PkList, []),
    % wait for packet receptions from other gateways
    Recent2 =
        lists:foldl(
            fun(Frame, Dict) -> store_frame(Frame, Dict) end,
            Recent, Unique),
    {noreply, State#state{recent=Recent2}};

handle_cast({downlink, Req, MAC, DevAddr, TxQ, RFCh, PHYPayload}, #state{pulladdr=Dict}=State) ->
    % lager:debug("<-- datr ~s, codr ~s, tmst ~B, size ~B", [TxQ#txq.datr, TxQ#txq.codr, TxQ#txq.tmst, byte_size(PHYPayload)]),
    case dict:find(MAC, Dict) of
        {ok, {Process, Target}} ->
            % send data to the gateway interface handler
            gen_server:cast(Process, {send, Target, Req, DevAddr, TxQ, RFCh, PHYPayload});
        error ->
            lager:warning("Downlink request ignored. Gateway ~w not connected.", [MAC])
    end,
    {noreply, State};

handle_cast({downlink_error, MAC, undefined, Error}, State) ->
    lorawan_utils:throw_error({gateway, MAC}, Error),
    {noreply, State};
handle_cast({downlink_error, _MAC, DevAddr, Error}, State) ->
    lorawan_utils:throw_error({node, DevAddr}, Error),
    {noreply, State}.



tx_air_time(PL, SF, CR, BW, DE) ->
    TSym = math:pow(2, SF)/BW,
    % lorawan uses an explicit header
    PayloadSymbNb = 8 + max(tx_ceiling((8*PL-4*SF+28+16)/(4*(SF-2*DE)))*CR, 0),
    % lorawan uses 8 symbols preamble
    % the last +1 is a correction based on practical experiments
    1000*((8 + 4.25) + PayloadSymbNb + 1)*TSym.

tx_ceiling(X) ->
    T = erlang:trunc(X),
    case (X - T) of
        Neg when Neg < 0 -> T;
        Pos when Pos > 0 -> T + 1;
        _ -> T
    end.


handle_TxData() ->
    {atomic, PendingFrames} = mnesia:transaction(
        fun() ->
                mnesia:write_lock_table(txframes),
                PendingFrames = mnesia:match_object(txframes, #txframe{_='_'}, read),

                PendingFrames
        end),

    PendingDevAddr = lists:map(
  	fun(Frame) -> 
		Frame#txframe.devaddr
	end, 
	PendingFrames),

    io:fwrite("pending addr: ~p ~n", [PendingDevAddr]),
   
    ForTxData = lists:usort(PendingDevAddr),
    io:fwrite("after usort: ~p ~n", [ForTxData]),

    NumTxData = length(ForTxData),
    io:fwrite("NumTxData: ~p ~n", [NumTxData]),

    Limit_TxData = lists:sublist(ForTxData, 6),
    
    Bin_ForTxData = 
	lists:foldr(
		fun(Elem, Acc) ->
			<<Elem/binary, Acc/binary>>
		end,
		<<>>, Limit_TxData),

    Transition = length(Limit_TxData) * (tx_ceiling(tx_air_time(59, 12, 5, 125000, 1)) + 1000 + tx_ceiling(tx_air_time(5,12,5,125000,1))),
    io:fwrite("Transition: ~p~n", [Transition]),

    TxData = <<Transition:32, Bin_ForTxData/binary>>,
    io:fwrite("TxData: ~tp ~n", [TxData]),
    TxData.
    %TxData = <<Bin_ForTxData/binary>>,
    %io:fwrite("TxData: ~p ~n", [TxData]).

handle_info({process, PHYPayload}, #state{recent=Recent}=State) ->
    % find the best (for now)
    [{Req, MAC, RxQ}|_Rest] = lists:sort(
        fun({_R1, _M1, Q1}, {_R2, _M2, Q2}) ->
            Q1#rxq.rssi >= Q2#rxq.rssi
        end,
        dict:fetch(PHYPayload, Recent)),
    % lager:debug("--> datr ~s, codr ~s, tmst ~B, size ~B", [RxQ#rxq.datr, RxQ#rxq.codr, RxQ#rxq.tmst, byte_size(PHYPayload)]),
    wpool:cast(handler_pool, {Req, MAC, RxQ, PHYPayload}, available_worker),
    Recent2 = dict:erase(PHYPayload, Recent),
    {noreply, State#state{recent=Recent2}};

handle_info(beacon, #state{pulladdr = MACDict, beacon_timer = OldBeaconTimer}=State) ->
    erlang:cancel_timer(OldBeaconTimer),
    lager:debug("[beacon] system_time = ~p", [erlang:system_time(millisecond)]),
    
    % send beacon
    TxData = handle_TxData(),

    {TxQ, PHYPayload} = lorawan_mac:handle_beacon(TxData),
    lager:debug("[beacon] TxQ = ~p", [TxQ]),
    lager:debug("[beacon] PHYPayload = ~p", [PHYPayload]),
    lists:foreach(
        fun(MAC) ->
            lager:debug("[beacon] MAC = ~p", [MAC]),
            lorawan_gw_router:downlink(#request{}, MAC, <<0:32>>, TxQ, PHYPayload)
        end,
        dict:fetch_keys(MACDict)),

    io:fwrite("send beacon\r\n"),

    % next beacon timer
    NewBeaconTimer = erlang:send_after(128000, self(), beacon),

    {noreply, State#state{beacon_timer = NewBeaconTimer}};

handle_info(pending_downlink, #state{pulladdr = MACDict, downlink_timer = Old_donwlinkTimer}=State) ->
    erlang:cancel_timer(Old_donwlinkTimer),
    
    io:fwrite("handle pending INIT~n"),

    % make downlink
    {atomic, All_links} = mnesia:transaction(
    fun() ->
        mnesia:write_lock_table(links),
        All_links = mnesia:match_object(links, #link{_='_'}, read),
        
        All_links
    end),

    % select DevAddr
    case All_links of
        [] -> io:fwrite("No connected devices~n"),
              ok;
        Links ->
            Link = lists:nth(rand:uniform(length(All_links)), All_links),
    
    	    Picked_Addr = Link#link.devaddr,    
            %io:fwrite("Picked_addr: ~p ~n", [Picked_Addr]),

            % make txdata
            lorawan_handler:store_frame(Picked_Addr, #txdata{data = <<01>>}),
            io:fwrite("store downlink frame: ~p ~n", [Picked_Addr]),
	    lager:info("pending_downlink : ~p", [Picked_Addr])

    end,

    Lambda = 1/20,
    NextTime = -math:log(1.0 - rand:uniform()) / Lambda,
    NextInterval = tx_ceiling(NextTime * 1000),     

    io:fwrite("Next interval: ~p ~n", [NextInterval]),

    % next downlink timer
    NewDownlink_timer = erlang:send_after(NextInterval, self(), pending_downlink),

    {noreply, State#state{downlink_timer = NewDownlink_timer}}.

terminate(Reason, _State) ->
    % record graceful shutdown in the log
    lager:info("gateway router terminated: ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


remove_duplicates([{Req, MAC, RxQ, PHYPayload} | Tail], Unique) ->
    % check if the first element is duplicate
    case lists:keytake(PHYPayload, 4, Tail) of
        {value, {Req2, MAC2, RxQ2, PHYPayload}, Tail2} ->
            % select element of a better quality and re-check for other duplicates
            if
                RxQ#rxq.rssi >= RxQ2#rxq.rssi ->
                    remove_duplicates([{Req, MAC, RxQ, PHYPayload} | Tail2], Unique);
                true -> % else
                    remove_duplicates([{Req2, MAC2, RxQ2, PHYPayload} | Tail2], Unique)
            end;
        false ->
            remove_duplicates(Tail, [{Req, MAC, RxQ, PHYPayload} | Unique])
    end;
remove_duplicates([], Unique) ->
    Unique.

store_frame({Req, MAC, RxQ, PHYPayload}, Dict) ->
    case dict:find(PHYPayload, Dict) of
        {ok, Frames} ->
            dict:store(PHYPayload, [{Req, MAC, RxQ}|Frames], Dict);
        error ->
            {ok, Delay} = application:get_env(lorawan_server, deduplication_delay),
            {ok, _} = timer:send_after(Delay, {process, PHYPayload}),
            dict:store(PHYPayload, [{Req, MAC, RxQ}], Dict)
    end.

% end of file

