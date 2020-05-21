%%%-------------------------------------------------------------------
%%% @author Lorenzo_Stacchio
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. mag 2020 11:44
%%%-------------------------------------------------------------------
-module(user).
-author("Lorenzo_Stacchio").
%% API
-export([start/0, start_loop/4, places_manager/1, get_places/3, test_manager/1, visit_manager/2]).
-define(TIMEOUT_PLACE_MANAGER, 10000).
-define(TIMEOUT_TEST_MANAGER, 5000).
% number of places a user keep track
-define(USER_PLACES_NUMBER, 3).


flush_new_places() ->
  receive
    {new_places, _} -> flush_new_places()
  after
    0 -> ok
  end.

sleep(T) -> receive after T -> ok end.

sleep_visit(T, PLACE_PID, Ref) ->
  receive {exit_quarantena} -> PLACE_PID ! {end_visit, self(), Ref}, exit(quarantena) after T -> ok end.

%----------------------USER----------------------
%-----------Topology maintenance protocol-----------

get_random_elements_from_list(ACTIVE_PLACES, N, LIST_USER) ->
  if length(LIST_USER) < N ->
    X = rand:uniform(length(ACTIVE_PLACES)),
    % check pre-existance of place in LIST_USER because server sends already delivered places
    case lists:member(lists:nth(X, ACTIVE_PLACES), LIST_USER) of
      true -> get_random_elements_from_list(ACTIVE_PLACES, N, LIST_USER);
      false ->
        get_random_elements_from_list(lists:delete(lists:nth(X, ACTIVE_PLACES), ACTIVE_PLACES),
          N, lists:append(LIST_USER, [lists:nth(X, ACTIVE_PLACES)]))
    end;
    true ->
      LIST_USER
  end.


% retrieves N places and add their PID to LIST_TO_RETURN, answer to PID when completed
get_places(N, LIST_TO_RETURN, PID) ->
  if
    length(LIST_TO_RETURN) < N ->
      global:whereis_name(server) ! {get_places, self()},
      receive
        {places, ACTIVE_PLACES} ->
          io:format("PLACES RICEVUTI~p~n", [ACTIVE_PLACES]),
          case length(ACTIVE_PLACES) >= N of
            true ->
              get_places(N, get_random_elements_from_list(ACTIVE_PLACES, N, LIST_TO_RETURN), PID);
            % not enough active places, die
            false -> exit(normal)
          end
      end;
    true -> PID ! {new_places, LIST_TO_RETURN}, visit_manager ! {new_places, LIST_TO_RETURN}
  end.


% responsible to keeping up to {USER_PLACES_NUMBER} places
places_manager(USER_PLACES_LIST) ->
  process_flag(trap_exit, true), % places_manager need to know if a place has died to request new places to server
  case length(USER_PLACES_LIST) < ?USER_PLACES_NUMBER of
    true ->
      spawn_monitor(?MODULE, get_places, [?USER_PLACES_NUMBER, USER_PLACES_LIST, self()]);
    false ->
      sleep(?TIMEOUT_PLACE_MANAGER)
  end,
  % spawn a process to asynchronously retrieve up to {USER_PLACES_NUMBER} places
  receive
    {'DOWN', _, process, PID, _} -> % a place have died
      case ((length(USER_PLACES_LIST) > 0) and lists:member(PID, USER_PLACES_LIST)) of
        true -> %exit(PID_GETTER, kill),
          io:format("Post mortem PLACE MANAGER2 ~p,~p,~p,~n", [PID, USER_PLACES_LIST--[PID], length(USER_PLACES_LIST--[PID])]),
          flush_new_places(),
          % clear the message queue
          places_manager(USER_PLACES_LIST--[PID]);
        false -> places_manager(USER_PLACES_LIST)
      end;
  %end;
    {new_places, NEW_PLACES} -> % message received from the spawned process that asked the new places
      io:format("PLACES MANTAINER UPDATED~p,~p,~n", [NEW_PLACES, length(NEW_PLACES)]),
      [monitor(process, PID) || PID <- NEW_PLACES],% create a link to all this new places
      places_manager(NEW_PLACES)
  end.

%-----------Visit protocol-----------
visit_manager(USER_PLACES, CONTACT_LIST) ->
  process_flag(trap_exit, true),
  % Not blocking receive to get places updates (if any)
  receive
    {'EXIT', PID, _} ->
      io:format("VISITOR DEATH OF~p~p~n",[PID,lists:member(PID, CONTACT_LIST)]),
      case lists:member(PID, CONTACT_LIST) of
        true ->  io:format("~pEntro in quarantena~n", [self()]),exit(quarantena);
        false -> ok
      end;
    {'DOWN', _, process, PID, _} ->
      case lists:member(PID, USER_PLACES) of % a user place died
        true -> io:format("Post mortem in VISIT ~p,~p, ~n", [PID, USER_PLACES--[PID]]),
          flush_new_places(),
          visit_manager(USER_PLACES--[PID], CONTACT_LIST);
        false -> %if false, the PID could only identify a Place or another user, because of the link made only to the Server and Places.
          case lists:member(PID, CONTACT_LIST) of
            true -> % a person which this user had been in contact has been diagnosed positive
              io:format("~p:Lista contatti~n", [CONTACT_LIST]), io:format("~p: morto~n", [PID]),
              io:format("~p: Entro in quarantena~n", [self()]), exit(quarantena);
            false -> ok %the PID was referring to a place that was not in the contact list, do nothing
          end
      end;
    {new_places, UL} ->
      io:format("VISIT MANAGER Update RIPETO~p ~n", [UL]),
      [monitor(process, PID) || PID <- UL],
      visit_manager(UL, CONTACT_LIST);
    {contact, PID_TOUCH} -> io:format("~pCONTACT WITH ~p ~n", [self(), PID_TOUCH]),
      link(PID_TOUCH),
      visit_manager(USER_PLACES, CONTACT_LIST ++ [PID_TOUCH])
  after 0 ->
    ok
  end,
  case length(USER_PLACES) == 0 of
    true ->
      receive
        {new_places, UL2} ->
          io:format("VISIT MANAGER Update RIPETO~p ~n", [UL2]),
          [monitor(process, PID) || PID <- UL2],
          visit_manager(UL2, CONTACT_LIST)
      end;
    false ->
      %io:format("VISIT MANAGER FALSE ~p ~n", [L]),
      sleep(2 + rand:uniform(3)), % wait for 3-5 as project requirements
      Ref = make_ref(),
      % choose one random place to visit
      P = lists:nth(rand:uniform(length(USER_PLACES)), USER_PLACES),
      %io:format("VISITING MANAGER User:~p,Place:~p ~n", [self(),P]),
      P ! {begin_visit, self(), Ref},
      sleep_visit(4 + rand:uniform(6), P, Ref), % visit duration as projects requirements
      P ! {end_visit, self(), Ref},
      visit_manager(USER_PLACES, CONTACT_LIST)
  end.

%-----------Test protocol-----------
% user asks hospital to make illness tests
test_manager(VISITOR_PID) ->
  sleep(?TIMEOUT_TEST_MANAGER),
  case (rand:uniform(4) == 1) of
    true ->
      io:format("TEST covid ~p~n", [global:whereis_name(hospital) ! {test_me, self()}]),
      global:whereis_name(hospital) ! {test_me, self()},
      receive
        positive -> io:format("~p:Entro in quarantena~n", [self()]), VISITOR_PID ! {exit_quarantena}, exit(quarantena);
        negative -> io:format("~p NEGATIVO~n", [self()]), test_manager(VISITOR_PID)
      end;
    false ->
      test_manager(VISITOR_PID)
  end.

%-----------Monitor  protocol-----------
%-----------Main-----------
% if the server dies, kill everything
start_loop(PLACES_MANAGER, VISIT_MANAGER, TEST_MANAGER, SERVER_PID) ->
  %TODO: GESTIRE MORTI DEI SINGOLI SOTTO-PROCESSI
  process_flag(trap_exit, true),
  [link(P_SP) || P_SP <- [PLACES_MANAGER, VISIT_MANAGER, TEST_MANAGER]],
  receive {'EXIT', SERVER_PID, _} ->
    io:format("MORTO SERVER~p~p~n", [SERVER_PID, [PLACES_MANAGER, VISIT_MANAGER, TEST_MANAGER]]),
    [exit(P, kill) || P <- [PLACES_MANAGER, VISIT_MANAGER, TEST_MANAGER]],
    exit(kill);
    {'EXIT', PLACES_MANAGER, _} -> PLACES_MANAGER2 = spawn(?MODULE, places_manager, [[]]),
      register(places_manager, PLACES_MANAGER2),
      start_loop(PLACES_MANAGER2, VISIT_MANAGER, TEST_MANAGER, SERVER_PID);
    {'EXIT', VISIT_MANAGER, Reason} ->
      case Reason == quarantena of
        true -> [exit(P, kill) || P <- [PLACES_MANAGER, TEST_MANAGER]],
          exit(kill);
        false ->
          unlink(TEST_MANAGER),
          exit(TEST_MANAGER, kill),
          VISIT_MANAGER = spawn(?MODULE, visit_manager, [[], []]),
          register(visit_manager, VISIT_MANAGER),
          TEST_MANAGER = spawn(?MODULE, test_manager, [VISIT_MANAGER]),
          register(test_manager, TEST_MANAGER),
          start_loop(PLACES_MANAGER, VISIT_MANAGER, TEST_MANAGER, SERVER_PID)
      end;
    {'EXIT', TEST_MANAGER, Reason} ->
      case Reason == quarantena of
        true -> [exit(P, kill) || P <- [PLACES_MANAGER, VISIT_MANAGER]],
          exit(kill);
        false -> TEST_MANAGER = spawn(?MODULE, test_manager, [VISIT_MANAGER]),
          register(test_manager, TEST_MANAGER),
          start_loop(PLACES_MANAGER, VISIT_MANAGER, TEST_MANAGER, SERVER_PID)
      end,
      TEST_MANAGER = spawn(?MODULE, test_manager, [VISIT_MANAGER]),
      register(test_manager, TEST_MANAGER),
      start_loop(PLACES_MANAGER, VISIT_MANAGER, TEST_MANAGER, SERVER_PID)
  end.


start() ->
  sleep(2000),
  %mettere link al server
  io:format("hospital ping result: ~p~n", [net_adm:ping(list_to_atom("hospital@" ++ net_adm:localhost()))]),
  PLACES_MANAGER = spawn(?MODULE, places_manager, [[]]),
  register(places_manager, PLACES_MANAGER),
  io:format("PLACES MANAGER SPAWNED~p~n", [PLACES_MANAGER]),
  VISIT_MANAGER = spawn(?MODULE, visit_manager, [[], []]),
  register(visit_manager, VISIT_MANAGER),
  io:format("VISITOR MANAGER SPAWNED~p~n", [VISIT_MANAGER]),
  TEST_MANAGER = spawn(?MODULE, test_manager, [VISIT_MANAGER]),
  register(test_manager, TEST_MANAGER),
  io:format("TEST MANAGER SPAWNED~p~n", [TEST_MANAGER]),
  spawn(?MODULE, start_loop, [PLACES_MANAGER, VISIT_MANAGER, TEST_MANAGER, global:whereis_name(server)]).
