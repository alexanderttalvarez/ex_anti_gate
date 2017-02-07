defmodule ExAntiGate do
  @moduledoc """
  This is documentation for ExAntiGate - unofficial [anti-captcha.com](http://anti-captcha.com)
  ([antigate.com](http://antigate.com)) API client for Elixir. The antigate service solves captchas
  by human workers.

  ## Disclaimer
  This project has been intended for fair use only. It's not allowed to use it for any destructive,
  anti-social and/or illegal activity.

  ## Configuration
  The Antigate client has to be configured. At least `api_key` MUST be set, otherwise the client
  is shutting down with a notice. It's possible to set it in config file or via environment variable
  `EX_ANTI_GATE_API_KEY`. Note: in case of both (system and config) options exist at the same time
  the environment variable value will be used.

  Default options look like this:

      config :ex_anti_gate,
          autostart: true, # Start ExAntiGate process on application start
          http_client: HTTPoison, # http client - change for testing proposes only

          # ############################# task options #####################################

          api_key: nil,
          api_host: "https://api.anti-captcha.com",
          language_pool: "en",             # "en" (default) - english queue,
                                           # "rn" - Russian, Ukrainian, Belorussian, Kazakh language group
          result_request_interval: 10_000, # result request first attemt interval, in milliseconds
          result_retry_interval: 2_000,     # delay between captcha status checks, in milliseconds
          no_slot_retry_interval: 5_000,   # delay between retries to catch a free slot to proceed captcha, in milliseconds
          no_slot_max_retries: 0,          # number of retries to catch a free slot,
                                           # 0 - until (max_timeout - result_request_inteval) milliseconds gone
          max_timeout: 120_000,            # captcha recognition maximum timeout;
                                           # the result value must be read during this period
          phrase: false,                   # does captcha have one or more spaces
          case: false,                     # captcha is case sensetive
          numeric: 0,                      # 0 - any symbols
                                           # 1 - captcha has digits only
                                           # 2 - captcha has any symbols EXCEPT digits
          math: false,                     # captcha is a math equation and it's necessary to solve it and enter result
          min_length: 0,                   # 0 - has no limits
                                           # > 0 - an integer sets minimum captcha length
          max_length: 0, # 0 - has no limits
                         # > 0 - an integer sets maximum captcha length
          push: false    # do not reply to the sender by default (wait for a result request)

  ## Using
  It is possible to use it in standard and push mode.

  In standard mode you send a task request with `ExAntiGate.solve_text_task/2` function and then can
  request current result with `ExAntiGate.get_task_result/1` or a full task stack with `ExAntiGate.get_task/1`.
  `get_task_result/1` is preferable.

  In push mode you should wait for two kind of tuples:
    * `{:ex_anti_gate_result, {:ready, task_uuid :: String.t(), result :: any}}` in case of successfull task or
    * `{:ex_anti_gate_result, {:error, task_uuid :: String.t(), error_id :: integer, error_code :: String.t(), error_description :: String.t()}}` - in
   case of any errors.

  For example:

      defmodule MyCaptchaDispatcher do
        use GenServer

        # ...

        # Server API

        def handle_info({:ex_anti_gate_result, {:ready, task_uuid, %{text: text} = _result}}, state) do
          # deal with captcha text
        end

        def handle_info({:ex_anti_gate_result, {:error, task_uuid, error_id, error_code, error_description}}, state) do
          # deal with error
        end

      end

  Please beware that in push mode task data disappear right after message is sent without any kind of delivery check and
  in standard mode task data disappear after `max_timeout` amount of time.

  ## Errors
  You can find most errors description in the [Antigate documentation](https://anticaptcha.atlassian.net/wiki/display/API/Errors).
  A number of errors came from this client implementation and have negative codes:
  `error_id`: -1, `error_code`: "ERROR_UNKNOWN_ERROR",       `error_description`: will be taken from the error source
  `error_id`: -2, `error_code`: "ERROR_API_TIMEOUT",         `error_description`: "Maximum timeout reached, task interrupted."
  `error_id`: -3, `error_code`: "ERROR_NO_SLOT_MAX_RETRIES", `error_description`: "Maximum attempts to catch free slot reached, task interrupted."

  """

  @task_defaults %{
                    from: nil,
                    timer: nil,
                    type: nil,
                    image: nil,
                    no_slot_attempts: 0,
                    status: :waiting, # or :ok, or :error
                    result: :none,
                    api_task_id: nil
                  }

  use GenServer
  require Logger
  import Ecto.UUID, only: [generate: 0]

  alias ExAntiGate.Config

  # #########################################################
  # Client API
  # #########################################################

  @doc """
  Starts the antigate client linked process
  """
  def start_link(initial_state \\ %{}) do
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  @doc """
  Starts the antigate client process
  """
  def start(initial_state \\ %{}) do
    GenServer.start(__MODULE__, initial_state, name: __MODULE__)
  end

  @doc """
  Creates a new task for a text captcha image
  Returns a UUID string as a task id
  """
  @spec solve_text_task(String.t(), List) :: String.t()
  def solve_text_task(image, options \\ []) do
    GenServer.call(__MODULE__, {:solve_text, image, options})
  end

  @doc """
  Returns task's current full structure by uuid
  """
  def get_task(task_uuid) do
    GenServer.call(__MODULE__, {:get_task, task_uuid})
  end

  @doc """
  Returns task current status with result as one of the following:
    * `{:waiting, :none}` - waiting for result
    * `{:ready, result :: any}` - captcha solved; the second param has result (text captcha result is `%{text :: String.t()}`)
    * `{:error, {error_id :: integer, error_code :: String.t(), error_description :: String.t()}}` - an error with description
  """
  def get_task_result(task_uuid) do
    GenServer.call(__MODULE__, {:get_task_result, task_uuid})
  end

  @doc false
  def proceed_result(result, task_uuid) do
    GenServer.cast(__MODULE__, {:proceed_result, task_uuid, result})
  end

  # #########################################################
  # Server API
  # #########################################################

  @doc false
  def handle_call({:get_task, task_uuid}, _from, state) do
    Logger.debug "ExAntiGate: get_task call, uuid: #{task_uuid}"
    {:reply, Map.get(state, task_uuid), state}
  end

  @doc false
  def handle_call({:get_task_result, task_uuid}, _from, state) do
    Logger.debug "ExAntiGate: get_task_result call, uuid: #{task_uuid}"
    {:reply, {get_in(state, [task_uuid, :status]), get_in(state, [task_uuid, :result])}, state}
  end

  # generate task uuid, put image data into state, send request to antigate
  # and return task uuid
  @doc false
  def handle_call({:solve_text, image, options}, from, state) do
    task_uuid = generate()
    options = merge_options(options)
    timer = Process.send_after(self(), {:cancel_task_timeout, task_uuid}, options.max_timeout)

    task = Map.merge(options, %{from: from, image: image, type: "ImageToTextTask", timer: timer})

    Process.send(self(), {:api_create_task, task_uuid}, [])

    Logger.debug "ExAntiGate: solve_text call, uuid: #{task_uuid}"

    {:reply, task_uuid, Map.merge(state, %{task_uuid => task})}
  end

  @doc false
  def handle_cast({:proceed_result, task_uuid, result}, state) do
    state = proceed_response(task_uuid, result, state)

    {:noreply, state}
  end

  # create task on API backend
  @doc false
  def handle_info({:api_create_task, task_uuid}, state) do
    case Map.get(state, task_uuid) do
      nil -> false

      task ->
        unless Map.get(task, :fake), do:
          spawn fn ->
            task_request = Poison.encode!(gen_task_request(task))

            Logger.debug "ExAntiGate: api_create_task call, sending request, uuid: #{task_uuid}, request: #{task_request}"
            response = task.http_client.post("#{task.api_host}/createTask", task_request, [{"Content-Type", "application/json"}])
            Logger.debug "ExAntiGate: api_create_task call, got response, uuid: #{task_uuid}, response: #{inspect response}"
            ExAntiGate.proceed_result(response, task_uuid)
          end
    end

    {:noreply, state}
  end

  # request task result from API backend
  @doc false
  def handle_info({:api_get_task_result, task_uuid}, state) do

    case Map.get(state, task_uuid) do
      nil -> false

      task ->
        unless Map.get(task, :fake), do:
          spawn fn ->
            Logger.debug "ExAntiGate: api_get_task_result call, sending request, uuid: #{task_uuid}"
            response = task.http_client.post("#{task.api_host}/getTaskResult", Poison.encode!(%{clientKey: task.api_key, taskId: task.api_task_id}), [{"Content-Type", "application/json"}])
            Logger.debug "ExAntiGate: api_get_task_result call, got response, uuid: #{task_uuid}, response: #{inspect response}"
            ExAntiGate.proceed_result(response, task_uuid)
          end
    end

    {:noreply, state}
  end

  # handle max timeout
  @doc false
  def handle_info({:cancel_task_timeout, task_uuid}, state) do
    state =
      task_uuid
      |> parse_error(%{"errorId" => -2, "errorCode" => "ERROR_API_TIMEOUT", "errorDescription" => "Maximum timeout reached, task interrupted."}, state)
      |> Map.delete(task_uuid)

    {:noreply, state}
  end

  # handle max timeout
  @doc false
  def handle_info({:cancel_task_no_slot, task_uuid}, state) do
    state =
      task_uuid
      |> parse_error(%{"errorId" => -3, "errorCode" => "ERROR_NO_SLOT_MAX_RETRIES", "errorDescription" => "Maximum attempts to catch free slot reached, task interrupted."}, state)
      |> Map.delete(task_uuid)

    {:noreply, state}
  end

  # ################################################### #
  #            proceed API request results              #
  # ################################################### #

  # check for task
  defp proceed_response(task_uuid, response, state) do
    # could be rewriten inline, but this is for better code readability
    task = Map.get(state, task_uuid)
    proceed_response(task, task_uuid, response, state)
  end

  # no task with such uuid - do nothing
  defp proceed_response(task, _task_uuid, _response, state) when is_nil(task) do
    state
  end
  # Got a normal HTTP response
  defp proceed_response(task, task_uuid, {:ok, %HTTPoison.Response{body: body, status_code: 200}} = _response, state) do
    json_decode_result = Poison.decode(body)
    proceed_response(task, task_uuid, json_decode_result, state)
  end
  # API task ID
  defp proceed_response(task, task_uuid, {:ok, %{"errorId" => 0, "taskId" => api_task_id} = _json_body}, state) do
    Process.send_after(self(), {:api_get_task_result, task_uuid}, task.result_request_interval)
    put_in(state, [task_uuid, :api_task_id], api_task_id)
  end
  # Set a timer to try again if the task is still processing
  defp proceed_response(task, task_uuid, {:ok, %{"errorId" => 0, "status" => "processing"} = _json_body}, state) do
    Process.send_after(self(), {:api_get_task_result, task_uuid}, task.result_retry_interval)
    state
  end
  # Deal with result if the task is done and task type is Image
  # in case of push: true
  defp proceed_response(
          %{type: "ImageToTextTask"} = task, task_uuid,
           {:ok, %{"errorId" => 0, "status" => "ready", "solution" => %{"text" => text}} = _json_body},
           state) do

    state
    |> put_in([task_uuid, :result], %{text: text})
    |> put_in([task_uuid, :status], :ready)
    |> push_data(task, task_uuid, {:ready, task_uuid, %{text: text}})
  end

  # Any other - probably an error
  defp proceed_response(_task, task_uuid, error, state) do
    parse_error(task_uuid, error, state)
  end

  # ################################################### #
  #                  proceed errors                     #
  # ################################################### #

  # try to get task
  defp parse_error(task_uuid, error, state) when is_binary task_uuid do
    task = Map.get(state, task_uuid)
    parse_error(task, task_uuid, error, state)
  end

  # if task is nil just return state
  defp parse_error(task, _task_uuid, _error, state) when is_nil task do
    state
  end
  # if error is HTTPoison client error
  defp parse_error(task, task_uuid, {:error, %HTTPoison.Error{id: error_id, reason: error_code}}, state) do
    proceed_error(task, task_uuid, {error_id, error_code, nil}, state)
  end
  # If error is API or timeout error
  defp parse_error(task, task_uuid, {:ok, %{"errorCode" => error_code, "errorDescription" => error_descr, "errorId" => error_id}}, state) do
    proceed_error(task, task_uuid, {error_id, error_code, error_descr}, state)
  end
  defp parse_error(task, task_uuid, %{"errorCode" => error_code, "errorDescription" => error_descr, "errorId" => error_id}, state) do
    proceed_error(task, task_uuid, {error_id, error_code, error_descr}, state)
  end
  # Any other (unknown?) errors
  defp parse_error(task, task_uuid, error, state) do
    proceed_error(task, task_uuid, {-1, "ERROR_UNKNOWN_ERROR", inspect error}, state)
  end

  # if ERROR_NO_SLOT_AVAILABLE retry after `no_slot_retry_interval` and increment `no_slot_attempts`
  defp proceed_error(task, task_uuid, {error_id, _error_code, _error_descr}, state) when error_id == 2 do
    if task.no_slot_max_retries == 0 or task.no_slot_attempts <= task.no_slot_max_retries do
      Process.send_after(self(), {:api_create_task, task_uuid}, task.no_slot_retry_interval)
      update_in(state, [task_uuid, :no_slot_attempts], &(&1 + 1))
    else
      Process.send(self(), {:cancel_task_no_slot, task_uuid}, [])
      state
    end
  end
  # All other errors
  defp proceed_error(task, task_uuid, {error_id, error_code, error_descr}, state) do
    state
    |> put_in([task_uuid, :result], {error_id, error_code, error_descr})
    |> put_in([task_uuid, :status], :error)
    |> push_data(task, task_uuid, {:error, task_uuid, error_id, error_code, error_descr})
  end

  # ####################### #
  # if we need to push data #
  # ####################### #
  defp push_data(state, task, task_uuid, data, delete_task \\ true)
  defp push_data(state, %{push: true, from: {to, _}, timer: timer} = _task, task_uuid, data, delete_task) do
    Process.send(to, {:ex_anti_gate_result, data}, [])
    if delete_task do
      Process.cancel_timer(timer)
      Map.delete(state, task_uuid)
    else
      state
    end
  end
  defp push_data(state, _task, _task_uuid, _data, _delete_task) do
    state
  end

  # Generate task request
  defp gen_task_request(full_task) do
    %{
        clientKey: full_task.api_key,
        softId: "829",
        languagePool: full_task.language_pool,
        task: gen_task(full_task)
    }
  end

  # Generate task object
  defp gen_task(%{type: "ImageToTextTask"} = full_task) do
    %{
       type: full_task.type,
       body: full_task.image,
       phrase: full_task.phrase,
       case: full_task.case,
       numeric: full_task.numeric,
       math: full_task.math,
       minLength: full_task.min_length,
       maxLength: full_task.max_length,
    }
  end
  defp gen_task(_full_task) do
    %{}
  end

  defp merge_options(options) do
    Config.get_all_env()
    |> Enum.concat(options)
    |> Enum.into(%{})
    |> Map.delete(:included_applications)
    |> Map.merge(@task_defaults)
  end

end
