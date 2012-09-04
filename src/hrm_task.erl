-module(hrm_task).

-behaviour(e2_task).

-export([create/2, create/5, update_meta/2, to_json/1]).

-export([start_link/1]).
-export([handle_task/1]).

-define(EC2_INTERVAL, 3000).

-include("../include/hrm_task.hrl").

%%%===================================================================
%%% Public API
%%%===================================================================

create(ActionUrl, CallbackUrl) ->
  create(ActionUrl, CallbackUrl, undefined, undefined, undefined).

create(ActionUrl, CallbackUrl, InstanceId, AccessKeyId, AccessKeySecret) ->
  Task = #task{
    id = uuid:uuid_to_string(uuid:get_v4()),
    action_url = ActionUrl,
    callback_url = CallbackUrl,
    instance_id = InstanceId,
    access_key_id = AccessKeyId,
    access_key_secret = AccessKeySecret,
    status = pending,
    started_at = hrm_utils:current_time()
  },
  case validate(Task) of
    [] ->
      hrm_storage:put(Task),
      hrm_tasks_sup:start_task_runner(Task),
      {ok, Task#task.id};
    Errors ->
      {errors, Errors}
  end.

update_meta(TaskId, Meta) ->
  hrm_storage:update(TaskId, fun (Task) ->
    Task#task{meta = Meta}
  end).

to_json(Task) when is_record(Task, task) ->
  Keys = record_info(fields, task),
  Values = lists:map(fun to_json/1, tl(tuple_to_list(Task))),
  jiffy:encode({lists:zip(Keys, Values)});
to_json(Value) when is_list(Value) -> list_to_binary(Value);
to_json(undefined) -> null;
to_json(Value) -> Value.

start_link(Task) ->
  e2_task:start_link(?MODULE, Task).

%%%===================================================================
%%% e2_task callbacks
%%%===================================================================

handle_task(Task) ->
  ok = ensure_instance(
    Task#task.instance_id,
    Task#task.access_key_id,
    Task#task.access_key_secret
  ),
  Task2 = do_action_request(Task),
  hrm_storage:put(Task2),
  do_callback_request(Task2),
  {stop, normal}.

%%%===================================================================
%%% Private
%%%===================================================================

%%% ensure_instance/3

ensure_instance(undefined, _, _) ->
  ok;
ensure_instance(InstanceId, AccessKeyId, AccessKeySecret) ->
  EC2 = erlaws_ec2:new(AccessKeyId, AccessKeySecret, true),
  handle_instance_state(InstanceId, EC2, get_instance_state(InstanceId, EC2)).

handle_instance_state(InstanceId, EC2, stopped) ->
  [{_, State, _}] = EC2:start_instances([InstanceId]),
  handle_instance_state(InstanceId, EC2, list_to_atom(State));

handle_instance_state(InstanceId, EC2, S) when S == pending; S == stopping ->
  timer:sleep(?EC2_INTERVAL),
  handle_instance_state(InstanceId, EC2, get_instance_state(InstanceId, EC2));

handle_instance_state(_, _, running) ->
  ok.

%%% do_action_request/1

do_action_request(Task) ->
  Params = [{hrm_task_id, Task#task.id}],
  Url = hrm_utils:append_query_params(Task#task.action_url, Params),
  {ok, {{_, StatusCode, _}, _, Body}} = httpc:request(Url),
  handle_action_response(Task, StatusCode, Body).

handle_action_response(Task, 200, _) ->
  Task#task{
    status = complete,
    completed_at = hrm_utils:current_time()
  };
handle_action_response(Task, StatusCode, Body) ->
  Task#task{
    status = error,
    meta = {[{status, StatusCode}, {message, list_to_binary(Body)}]},
    completed_at = hrm_utils:current_time()
  }.

%%% do_callback_request/1

do_callback_request(Task) ->
  Params = [{hrm_task_id, Task#task.id}, {hrm_task, to_json(Task)}],
  Url = hrm_utils:append_query_params(Task#task.callback_url, Params),
  {ok, _} = httpc:request(Url),
  ok.

%%% validate/1

validate(Task) ->
  ValidationResults = [
    {action_url,   validate_url(Task#task.action_url)},
    {callback_url, validate_url(Task#task.action_url)},
    {instance_id,  validate_ec2_instance(Task#task.instance_id, Task#task.access_key_id, Task#task.access_key_secret)}
  ],
  OkFilter = fun({_Field, Result}) ->
    Result =/= ok
  end,
  lists:filter(OkFilter, ValidationResults).

%%%===================================================================
%%% Common validation methods
%%%===================================================================

validate_url(undefined) ->
  undefined;
validate_url(Url) ->
  case uri:parse(Url) of
    {ok, _} -> ok;
    {error, _} -> malformed_url
  end.

validate_ec2_instance(undefined, _, _) ->
  ok;
validate_ec2_instance(InstanceId, AccessKey, AccessSecret) ->
  EC2 = erlaws_ec2:new(AccessKey, AccessSecret, true),
  validate_instance_state(get_instance_state(InstanceId, EC2)).

validate_instance_state(S) when
  S == stopped;
  S == pending;
  S == stopping;
  S == running
  -> ok;
validate_instance_state(not_found) -> not_found;
validate_instance_state(_) -> unexpected_state.

get_instance_state(InstanceId, EC2) ->
  case EC2:describe_instances([InstanceId]) of
    [] -> not_found;
    [InstanceData] -> iolist_to_atom(proplists:get_value(instance_state, InstanceData))
  end.
