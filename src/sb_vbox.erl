%% -------------------------------------------------------------------
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(sb_vbox).
-behaviour(stableboy_vm_backend).

-export([list/1, get/1, snapshot/1, rollback/1, brand/2]).

-define(LIST_CMD, "vboxmanage list vms").
-define(LISTRUNNING_CMD, "vboxmanage list runningvms").
-define(GET_XDATA_CMD(VM), "vboxmanage getextradata " ++ VM ++ " sb_info").
-define(SET_XDATA_CMD(VM,META), "vboxmanage setextradata " ++ VM ++ " sb_info " ++ META).
-define(GET_IPDATA_CMD(VM), "vboxmanage guestproperty get " ++ VM ++ " /VirtualBox/GuestInfo/Net/0/V4/IP").
-define(GET_PORTDATA_CMD(VM), "vboxmanage showvminfo " ++ VM ++ " | egrep \"name = .*ssh,.*host port = \"").
-define(START_CMD(VM), "vboxmanage startvm " ++ VM ++ " --type headless").
-define(FORCESTOP_CMD(VM), "VBoxManage controlvm " ++ VM ++ " poweroff").
-define(LISTSNAPSHOTS_CMD(VM), "vboxmanage snapshot " ++ VM ++ " list").
-define(VMSTATE_CMD(VM), "vboxmanage showvminfo --machinereadable " ++ VM ++ " | egrep VMState=").
-define(SNAPSHOT_CMD(VM), "vboxmanage snapshot " ++ VM ++ " take " ++ VM ++ "_stableboy").
-define(RESTORE_CMD(VM), "vboxmanage snapshot " ++ VM ++ " restore " ++ VM ++ "_stableboy").

%% List the available VM's
list([]) ->
    lager:debug("In sb_vbox:list (unfiltered)"),
    sb_vm_common:list_by_properties([{platform, '*'}], command(?LIST_CMD, fun format_list/1));
list([Filename]) ->
    lager:debug("In sb_vbox:list (filename)"),
    sb_vm_common:list_by_file(Filename, command(?LIST_CMD, fun format_list/1)).

% @doc Get login information about VMs by name
get ([]) ->
    ok;
get([Name|Rest]) ->
    ok = get_by_name(Name),
    ?MODULE:get(Rest).

%% @doc Get a VM by name (alias).
get_by_name(Alias) ->
    VMInfo = get_vm(Alias),
    sb_vm_common:print_result([VMInfo]),
    ok.

%% @doc Take a snapshot of the named VM. --safe will never delete an existing snapshot
%% There is only ever a single snapshot saved, known as the "current" snapshot. Taking
%% a new one will write over the old one.
%% cmd: vboxmanage take
snapshot (Alias) ->
    lager:debug("In sb_vbox:snapshot with args: ~p", [Alias]),
    Force = sb:get_config(force,false),
    Exists = snap_shot_exists(Alias),
    case Force orelse not Exists of
        false ->
            %% don't stomp existing snapshot in "safe" mode
            lager:error("Stableboy snapshot for ~s already exists. Use --force to overwrite.~n", [Alias]),
            ok;
        true ->
            command(?VMSTATE_CMD(Alias), Alias, fun format_snapshot/2),
            ok
    end.

%% @doc Restore the named VM to a previous snapshot. Fails with
%% error message and exit(1) if no snapshot is available.
rollback (Alias) ->
    lager:debug("In sb_vbox:rollback with args: ~p", [Alias]),
    case snap_shot_exists(Alias) of
        true ->
            command(?FORCESTOP_CMD(Alias)),
            wait_for_poweroff(Alias, sb:get_config(vbox_poweroff_timeout, 5)),
            command(?RESTORE_CMD(Alias), Alias, fun format_restore/2);
        false ->
            lager:error("sb_vbox: rollback for ~s failed because no snapshot was found.", [Alias]),
            halt(1)
    end,
    ok.

%% @doc Brands a VM with given metadata.
%% vboxmanage setextradata dimplecup sb_info "ubuntu:12.04:64"
brand(Alias, Meta) ->
    lager:debug("In sb_vbox:brand/1"),
    command(?SET_XDATA_CMD(Alias,Meta),
            fun(Output) -> lager:debug("Branding result: ~p", [Output]) end),
    ok.

%%-------------------
%% Internal functions
%%-------------------

wait_for_poweroff(Alias,0) -> {error, "Timed out waiting for VM " ++ Alias ++ " to power off."};
wait_for_poweroff(Alias,NTries) ->
    Output = command(?VMSTATE_CMD(Alias)),
    case re:run(Output, "poweroff") of
        {match, _} ->
            ok;
        nomatch ->
            timer:sleep(1000),
            wait_for_poweroff(Alias,NTries-1)
    end.

%% @doc Executes a command in the shell. The Callback is
%% called with the stdout stream so that the data can be formatted
%% before being returned.
command(Command, Callback) ->
    Output = os:cmd(Command),
    Callback(Output).

command(Command, Alias, Callback) ->
    Output = os:cmd(Command),
    Callback(Alias, Output).

command(Command) ->
    os:cmd(Command).

%% get info from extra data memory of VBox, which must have previously
%% been set by the user to describe their VM guest. For example, type
%% vboxmanage setextradata myVmName sb_info ubuntu:12.04:64
format_extra(Alias,Output) ->
    Unknown = {Alias,undefined,[],undefined,undefined,undefined},
    case re:split(Output, "[ \n]", [{return, list},trim]) of
        ["Value:",Xtra] ->
            case re:split(Xtra, "[:]", [{return, list},trim]) of
                [OS,Vdotted,Arch] ->
                    Vints = version_to_intlist(Vdotted),
                    {Alias,list_to_atom(OS),Vints,list_to_integer(Arch),none,none};
                [OS,Vdotted,Arch,User,Pass] ->
                    Vints = version_to_intlist(Vdotted),
                    {Alias,list_to_atom(OS),Vints,list_to_integer(Arch),User,Pass};
                _ ->
                    %% error msg?
                    lager:error("sb_info failed: Xtra = ~p~n", [Xtra]),
                    Unknown
            end;
        _ -> Unknown
    end.

%% Find the SSH port, even when it's Port Forwarded
format_portdata(Output) ->
    case re:split(Output, "host port = ", [{return, list},trim]) of
        [First|Rest] when First /= [] ->
            [Port|_Other] = re:split(Rest, "[ ,\"]", [{return, list},trim]),
            {forwarded,list_to_integer(Port)};
        _ ->
            %% Not set. Assume default
            {default,22}
    end.

%% @doc Format the output from the virtual box "list vms" command into just the names.
format_names(Output) ->
    Lines = [Line || Line <- re:split(Output, "[\n]", [{return, list}]), Line /= []],
    Lines2 = [re:split(Line, "[\"]", [{return, list}]) || Line <- Lines],
    lists:map(fun([_Blank,Alias|_ShaHash]) -> Alias end, Lines2).

%% @doc Format output for the 'list' command into Erlang terms.
format_list(Output) ->
    Names = format_names(Output),
    Xtras = [command(?GET_XDATA_CMD(Name), Name, fun format_extra/2) || Name <- Names],
    lists:map(fun({VM,OS,Ver,Arch,_User,_Pass}) -> {VM,OS,Ver,Arch} end, Xtras).

%% Take a snapshot iff the VM is in the poweroff state, otherwise error halt(1)
%% Output is like: VMState="poweroff" if all is good for snapshotting.
format_snapshot(Alias, Output) ->
    case re:run(Output, "poweroff") of
        {match, _} ->
            command(?SNAPSHOT_CMD(Alias), fun took_snapshot/1);
        nomatch ->
            Reason = "sb_vbox: failed to take snapshot on " ++ Alias ++ ". VM not powered off.",
            lager:error("~s", [Reason]),
            halt(1)
    end,
    ok.

%% Restore a VM snapshot, halt on failure.
format_restore(Alias,Output) ->
    case re:run(Output, "FAILURE") of
        nomatch ->
            ok;
        {match,_} ->
            Reason = "sb_vbox: failed to restore snapshot for VM: " ++ Alias,
            lager:error("~s: ~p", [Reason, Output]),
            halt(1)
    end.

%% @doc return boolean status of VM's running status
vm_is_running(Alias) ->
    Names = command(?LISTRUNNING_CMD, fun format_names/1),
    lists:member(Alias, Names).

%% @doc return whether a snapshot exists for a named VM
snap_shot_exists(Alias) ->
    Output = command(?LISTSNAPSHOTS_CMD(Alias)),
    Lines = [Line || Line <- re:split(Output, "[\n]", [{return, list}]), Line /= []],
    %% Result is 'true' if any line contains a stableboy match.
    lists:foldl(
      fun(Line, Accum) ->
              StableboySnapShotName = Alias ++ "_stableboy",
              Exists =
                  case re:run(Line, ".*Name: ([^ ]*) .*", [{capture,[1],list}]) of
                      {match, [StableboySnapShotName|_]} -> true;
                      {match, [_OtherSnapShotName|_]} -> false;
                      nomatch -> false
                  end,
              Exists or Accum
      end,
      false,
      Lines).

%% Try to make sure the VM is running before returning.
%% Sleeps 1 second between trys to start the VM
ensure_vm_started(_Alias, 0) -> error;
ensure_vm_started(Alias, NTries) ->
    case vm_is_running(Alias) of
        true ->
            ok;
        false ->
            timer:sleep(1000),
            ensure_vm_started(Alias, NTries-1)
    end.
ensure_vm_started(Alias) ->
    case vm_is_running(Alias) of
        true ->
            ok;
        false ->
            command(?START_CMD(Alias), fun started_vm/1),
            ensure_vm_started(Alias, 3)
    end.

%% @doc Get a VM by it's name
%% The VM has to be started in order to return it's IP address,
%% so it's always started by calling this function.
get_vm(VM) ->
    case command(?GET_XDATA_CMD(VM), VM, fun format_extra/2) of
        {_Alias, undefined, _, _, _, _} ->
            Names = command(?LIST_CMD, fun format_names/1),
            Reason = case lists:member(VM, Names) of
                         true -> "it's not branded.";
                         false -> "it doesn't exist."
                     end,
            {error, "sb_vbox:get VM '" ++ VM ++ "' failed because " ++ Reason};
        {_Alias,_OS,_Ver,_Arch,User,Pass} ->
            case ensure_vm_started(VM) of
                error ->
                    Reason = " it either failed to start or return an IP address.",
                    {error, "sb_vbox:get VM '" ++ VM ++ "' failed because " ++ Reason};
                ok ->
                    {IP,Port} = get_conn_data(VM),
                    {VM,IP,Port,User,Pass}
            end
    end.


%% @doc Wait for a VM's IP
%% used after rollback
wait_for_ip(Alias,0) -> {error, "Timed out waiting for VM " ++ Alias
                            ++ " IP address."};
wait_for_ip(Alias,NTries) ->
    Output = command(?GET_IPDATA_CMD(Alias)),
    case re:run(Output, "Value: (.*)", [{capture,[1],list}]) of
        {match, [Ip|_]} -> Ip;
        nomatch ->
            timer:sleep(1000),
            wait_for_ip(Alias,NTries-1)
    end.


%% @doc Get IP and Port address information for a named VM.
%% Fetches data from virtual box manager, including port forwarded ssh ports
%% providing that the port forwarding rule has the text "ssh" in it's name,
%% otherwise Port defaults to 22. IP addr is taken from the first NIC, namely
%% adapter 0.
get_conn_data(Name) ->
    % wait for up to 2 minutes for an IP
    Addr = wait_for_ip(Name,120),
    case command(?GET_PORTDATA_CMD(Name), fun format_portdata/1) of
        {forwarded,Port} ->
            %% if the Port is forwarded, use our localhost
            {"127.0.0.1", Port};
        {default,Port} ->
            {Addr, Port}
    end.

%% @doc Callback for result of starting a VM
started_vm(Output) ->
    lager:debug("Started VM! ~s", [Output]).

took_snapshot(Output) ->
    lager:debug("Took a snapshot! ~s", [Output]).

%% @doc Converts a dot-delimited version string into a list of version integers.
version_to_intlist(V) ->
    [ list_to_integer(P) || P <- re:split(V, "[.]", [{return,list},trim]) ].
