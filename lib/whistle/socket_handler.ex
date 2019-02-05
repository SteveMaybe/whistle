defmodule Whistle.SocketHandler do
  @behaviour :cowboy_websocket

  alias Whistle.{Program, Socket}

  require Whistle.Config

  @json_library Whistle.Config.json_library()

  def init(req, {router, []}) do
    conn = Plug.Cowboy.Conn.conn(req)
    {:cowboy_websocket, req, {conn, router}}
  end

  def websocket_init({conn, router}) do
    {:ok,
     %{
       socket: Socket.new(conn),
       router: router,
       programs: %{}
     }}
  end

  defp generate_connection_id() do
    4
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
  end

  def websocket_handle(
        {:text, payload},
        state = %{router: router, socket: socket, programs: programs}
      ) do
    payload
    |> @json_library.decode()
    |> case do
      {:ok, %{"type" => "event", "program" => program_name, "handler" => handler, "args" => args}} ->
        message = {:update, program_name, handler, args}

        websocket_info(message, state)

      {:ok, %{"type" => "route", "program" => program_id, "uri" => uri}} ->
        program = Map.get(programs, program_id)

        case Program.Connection.route(program, uri) do
          {:ok, new_program} ->
            {:ok, %{state | programs: Map.put(programs, program_id, new_program)}}

          {:error, _error} ->
            {:ok, state}
        end

      {:ok, %{"type" => "leave", "program" => program_id}} ->
        program = Map.get(programs, program_id)

        Program.Registry.unsubscribe(router, program.name, self())
        Program.Connection.notify_disconnection(program, socket)

        {:ok, %{state | programs: Map.delete(programs, program_id)}}

      {:ok,
       %{
         "type" => "join",
         "requestId" => request_id,
         "program" => program_name,
         "params" => params,
         "dom" => dom,
         "uri" => uri
       }} ->
        channel_path = String.split(program_name, ":")

        with {:ok, program, program_params} <- router.__match(channel_path),
             {:ok, _pid} <-
               Program.Registry.ensure_started(router, program_name, program, program_params),
             {:ok, new_socket, session} <-
               Program.Instance.authorize(
                 router,
                 program_name,
                 socket,
                 Map.merge(program_params, params)
               ),
             :ok <- Program.Registry.subscribe(router, program_name, self()) do
          program_connection = %Program.Connection{
            router: router,
            name: program_name,
            handlers: %{},
            vdom: {0, Whistle.Html.Dom.decode_node(dom)},
            session: session
          }

          program_id = generate_connection_id()

          response =
            @json_library.encode!(%{
              type: "joined",
              requestId: request_id,
              programId: program_id
            })

          Program.Connection.notify_connection(program_connection, socket)

          new_program =
            case Program.Connection.route(program_connection, uri) do
              {:ok, new_program} ->
                new_program

              {:error, _error} ->
                program_connection
            end

          send(self(), {:updated, program_name})

          {:reply, {:text, response},
           %{
             state
             | socket: new_socket,
               programs: Map.put(programs, program_id, new_program)
           }}
        end
    end
  end

  def terminate(_reason, _req, %{socket: socket, programs: programs}) do
    Enum.each(programs, fn {_, program} ->
      Program.Connection.notify_disconnection(program, socket)
    end)

    :ok
  end

  def websocket_info({:program_terminating, _program_name, _reason}, state) do
    # program died
    {:ok, state}
  end

  def websocket_info(
        {:program_started, program_name},
        state = %{socket: socket, programs: programs}
      ) do
    Enum.each(programs, fn program = %{name: ^program_name} ->
      Program.Connection.notify_connection(program, socket)
    end)

    reply_program_view(state, program_name)
  end

  def websocket_info({:update, program_name, handler, args}, state = %{programs: programs}) do
    program = Map.get(programs, program_name)

    case Program.Connection.update(program, {handler, args}) do
      {:ok, new_program, replies} ->
        new_state = %{state | programs: Map.put(programs, program_name, new_program)}

        if length(replies) > 0 do
          response =
            replies
            |> Enum.map(fn reply ->
              %{type: "msg", program: program_name, payload: reply}
            end)
            |> @json_library.encode!()

          {:reply, {:text, response}, new_state}
        else
          {:ok, new_state}
        end

      {:error, :program_crash} ->
        {:ok, state}
    end
  end

  def websocket_info({:updated, name}, state) do
    reply_program_view(state, name)
  end

  defp reply_program_view(state = %{programs: programs}, name) do
    {new_programs, responses} =
      Enum.reduce(programs, {[], []}, fn
        {id, program = %{name: ^name}}, {programs, responses} ->
          new_vdom = Program.Connection.view(program)
          {new_program, diff} = Program.Connection.put_new_vdom(program, new_vdom)

          new_responses =
            if length(diff) > 0 do
              response = %{
                type: "render",
                program: id,
                dom_patches: diff
              }

              responses ++ [response]
            else
              responses
            end

          {programs ++ [{id, new_program}], new_responses}

        program, {programs, responses} ->
          {programs ++ [program], responses}
      end)

    new_state = %{state | programs: Enum.into(new_programs, %{})}

    if length(responses) > 0 do
      {:reply, {:text, @json_library.encode!(responses)}, new_state}
    else
      {:ok, new_state}
    end
  end
end
