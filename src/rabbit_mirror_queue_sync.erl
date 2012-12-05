%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2010-2012 VMware, Inc.  All rights reserved.
%%

-module(rabbit_mirror_queue_sync).

-include("rabbit.hrl").

-export([master_prepare/3, master_go/5, slave/7]).

-define(SYNC_PROGRESS_INTERVAL, 1000000).

%% There are three processes around, the master, the syncer and the
%% slave(s). The syncer is an intermediary, linked to the master in
%% order to make sure we do not mess with the master's credit flow or
%% set of monitors.
%%
%% Interactions
%% ------------
%%
%% '*' indicates repeating messages. All are standard Erlang messages
%% except sync_start which is sent over GM to flush out any other
%% messages that we might have sent that way already. (credit) is the
%% usual credit_flow bump message every so often.
%%
%%               Master             Syncer                 Slave(s)
%% sync_mirrors -> ||                                         ||
%% (from channel)  || -- (spawns) --> ||                      ||
%%                 || --------- sync_start (over GM) -------> ||
%%                 ||                 || <--- sync_ready ---- ||
%%                 ||                 ||         (or)         ||
%%                 ||                 || <--- sync_deny ----- ||
%%                 || <--- next* ---- ||                      ||  }
%%                 || ---- msg* ----> ||                      ||  } loop
%%                 ||                 || ---- sync_msg* ----> ||  }
%%                 ||                 || <--- (credit)* ----- ||  }
%%                 || <--- next  ---- ||                      ||
%%                 || ---- done ----> ||                      ||
%%                 ||                 || -- sync_complete --> ||
%%                 ||               (Dies)                    ||

%% ---------------------------------------------------------------------------
%% Master

master_prepare(Ref, Log, SPids) ->
    MPid = self(),
    spawn_link(fun () -> syncer(Ref, Log, MPid, SPids) end).

master_go(Syncer, Ref, Log, BQ, BQS) ->
    Args = {Syncer, Ref, Log, rabbit_misc:get_parent()},
    case BQ:fold(fun (Msg, MsgProps, {I, Last}) ->
                         master_send(Args, I, Last, Msg, MsgProps)
                 end, {0, erlang:now()}, BQS) of
        {{shutdown,  Reason}, BQS1} -> {shutdown,  Reason, BQS1};
        {{sync_died, Reason}, BQS1} -> {sync_died, Reason, BQS1};
        {_,                   BQS1} -> master_done(Args, BQS1)
    end.

master_send({Syncer, Ref, Log, Parent}, I, Last, Msg, MsgProps) ->
    Acc = {I + 1,
           case timer:now_diff(erlang:now(), Last) > ?SYNC_PROGRESS_INTERVAL of
               true  -> Log("~p messages", [I]),
                        erlang:now();
               false -> Last
           end},
    receive
        {'$gen_cast', {set_maximum_since_use, Age}} ->
            ok = file_handle_cache:set_maximum_since_use(Age)
    after 0 ->
            ok
    end,
    receive
        {next, Ref}              -> Syncer ! {msg, Ref, Msg, MsgProps},
                                    {cont, Acc};
        {'EXIT', Parent, Reason} -> {stop, {shutdown,  Reason}};
        {'EXIT', Syncer, Reason} -> {stop, {sync_died, Reason}}
    end.

master_done({Syncer, Ref, _Log, Parent}, BQS) ->
    receive
        {next, Ref}              -> unlink(Syncer),
                                    Syncer ! {done, Ref},
                                    receive {'EXIT', Syncer, _} -> ok
                                    after 0 -> ok
                                    end,
                                    {ok, BQS};
        {'EXIT', Parent, Reason} -> {shutdown,  Reason, BQS};
        {'EXIT', Syncer, Reason} -> {sync_died, Reason, BQS}
    end.

%% Master
%% ---------------------------------------------------------------------------
%% Syncer

syncer(Ref, Log, MPid, SPids) ->
    SPidsMRefs = [{SPid, erlang:monitor(process, SPid)} || SPid <- SPids],
    %% We wait for a reply from the slaves so that we know they are in
    %% a receive block and will thus receive messages we send to them
    %% *without* those messages ending up in their gen_server2 pqueue.
    case foreach_slave(SPidsMRefs, Ref, fun sync_receive_ready/3) of
        []          -> Log("all slaves already synced", []);
        SPidsMRefs1 -> Log("~p to sync", [[rabbit_misc:pid_to_string(S) ||
                                              {S, _} <- SPidsMRefs1]]),
                       SPidsMRefs2 = syncer_loop({Ref, MPid}, SPidsMRefs1),
                       foreach_slave(SPidsMRefs2, Ref, fun sync_send_complete/3)
    end.

syncer_loop({Ref, MPid} = Args, SPidsMRefs) ->
    MPid ! {next, Ref},
    receive
        {msg, Ref, Msg, MsgProps} ->
            SPidsMRefs1 = wait_for_credit(SPidsMRefs, Ref),
            [begin
                 credit_flow:send(SPid),
                 SPid ! {sync_msg, Ref, Msg, MsgProps}
             end || {SPid, _} <- SPidsMRefs1],
            syncer_loop(Args, SPidsMRefs1);
        {done, Ref} ->
            SPidsMRefs
    end.

wait_for_credit(SPidsMRefs, Ref) ->
    case credit_flow:blocked() of
        true  -> wait_for_credit(foreach_slave(SPidsMRefs, Ref,
                                               fun sync_receive_credit/3), Ref);
        false -> SPidsMRefs
    end.

foreach_slave(SPidsMRefs, Ref, Fun) ->
    [{SPid, MRef} || {SPid, MRef} <- SPidsMRefs,
                     Fun(SPid, MRef, Ref) =/= ignore].

sync_receive_ready(SPid, MRef, Ref) ->
    receive
        {sync_ready, Ref, SPid}    -> SPid;
        {sync_deny,  Ref, SPid}    -> ignore;
        {'DOWN', MRef, _, SPid, _} -> ignore
    end.

sync_receive_credit(SPid, MRef, _Ref) ->
    receive
        {bump_credit, {SPid, _} = Msg} -> credit_flow:handle_bump_msg(Msg),
                                          SPid;
        {'DOWN', MRef, _, SPid, _}     -> credit_flow:peer_down(SPid),
                                          ignore
    end.

sync_send_complete(SPid, _MRef, Ref) ->
    SPid ! {sync_complete, Ref}.

%% Syncer
%% ---------------------------------------------------------------------------
%% Slave

slave(0, Ref, _TRef, Syncer, _BQ, _BQS, _UpdateRamDuration) ->
    Syncer ! {sync_deny, Ref, self()},
    denied;

slave(_DD, Ref, TRef, Syncer, BQ, BQS, UpdateRamDuration) ->
    MRef = erlang:monitor(process, Syncer),
    Syncer ! {sync_ready, Ref, self()},
    {_MsgCount, BQS1} = BQ:purge(BQS),
    slave_sync_loop({Ref, MRef, Syncer, BQ, UpdateRamDuration,
                     rabbit_misc:get_parent()}, TRef, BQS1).

slave_sync_loop(Args = {Ref, MRef, Syncer, BQ, UpdateRamDuration, Parent},
                TRef, BQS) ->
    receive
        {'DOWN', MRef, process, Syncer, _Reason} ->
            %% If the master dies half way we are not in the usual
            %% half-synced state (with messages nearer the tail of the
            %% queue); instead we have ones nearer the head. If we then
            %% sync with a newly promoted master, or even just receive
            %% messages from it, we have a hole in the middle. So the
            %% only thing to do here is purge.
            {_MsgCount, BQS1} = BQ:purge(BQS),
            credit_flow:peer_down(Syncer),
            {failed, {TRef, BQS1}};
        {bump_credit, Msg} ->
            credit_flow:handle_bump_msg(Msg),
            slave_sync_loop(Args, TRef, BQS);
        {sync_complete, Ref} ->
            erlang:demonitor(MRef, [flush]),
            credit_flow:peer_down(Syncer),
            {ok, {TRef, BQS}};
        {'$gen_cast', {set_maximum_since_use, Age}} ->
            ok = file_handle_cache:set_maximum_since_use(Age),
            slave_sync_loop(Args, TRef, BQS);
        {'$gen_cast', {set_ram_duration_target, Duration}} ->
            BQS1 = BQ:set_ram_duration_target(Duration, BQS),
            slave_sync_loop(Args, TRef, BQS1);
        update_ram_duration ->
            {TRef1, BQS1} = UpdateRamDuration(BQ, BQS),
            slave_sync_loop(Args, TRef1, BQS1);
        {sync_msg, Ref, Msg, Props} ->
            credit_flow:ack(Syncer),
            Props1 = Props#message_properties{needs_confirming = false},
            BQS1 = BQ:publish(Msg, Props1, true, none, BQS),
            slave_sync_loop(Args, TRef, BQS1);
        {'EXIT', Parent, Reason} ->
            {stop, Reason, {TRef, BQS}}
    end.