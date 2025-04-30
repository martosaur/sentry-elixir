defmodule Sentry.LoggerHandlerTest do
  use Sentry.Case, async: true

  import Sentry.TestHelpers
  require Logger

  setup_all {LoggerHandlerKit.Arrange, :ensure_per_handler_translation}

  setup context do
    pid = self()
    ref = make_ref()

    put_test_config(
      before_send: fn event ->
        send(pid, {ref, event})

        if Map.get(context, :send_request, false) do
          event
        else
          false
        end
      end,
      dsn: "http://public:secret@localhost:9392/1"
    )

    %{sender_ref: ref}
  end

  setup %{test: test} = context do
    big_config_override = Map.take(context, [:handle_otp_reports, :handle_sasl_reports])

    handler_config =
      case Map.fetch(context, :handler_config) do
        {:ok, config} -> config
        :error -> %{}
      end

    {context, on_exit} =
      LoggerHandlerKit.Arrange.add_handler(
        test,
        Sentry.LoggerHandler,
        handler_config,
        big_config_override
      )

    on_exit(on_exit)
    context
  end

  describe "Log messages" do
    @describetag handler_config: %{level: :info, capture_log_messages: true}

    @tag handler_config: %{capture_log_messages: true}
    test "sends error messages by default", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      Logger.error("Testing error")
      Logger.info("Testing info")

      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted == "Testing error"

      refute_receive {^sender_ref, _event}
    end

    @tag handler_config: %{level: :warning, capture_log_messages: true}
    test "skips logs from a lower level than the configured one", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      Logger.info("Info message")
      Logger.warning("Warning message")

      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, %{message: %{formatted: "Warning message"}}}
      refute_receive {^sender_ref, _}
    end

    test "support charlist", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.charlist_message()
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted == "Hello World"
    end

    test "support chardata", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.chardata_message()
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted == "Hello World"
    end

    test "support io format", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.io_format()
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted == "Hello World"
    end

    test "support structured logs keyword", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.keyword_report()
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted == "[hello: \"world\"]"
    end

    test "support structured logs map", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.map_report()
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted == "%{hello: \"world\"}"
    end

    test "support structured logs struct", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.struct_report()
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted == "%LoggerHandlerKit.FakeStruct{hello: \"world\"}"
    end

    test "handles malformed :callers metadata", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      dead_pid = spawn(fn -> :ok end)

      Logger.error("Error", callers: [dead_pid, nil])
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted == "Error"
    end

    @tag handler_config: %{capture_log_messages: true, excluded_domains: [:test_domain]}
    test "ignores log messages with excluded domains", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      Logger.error("test_domain", domain: [:test_domain])
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      refute_receive {^sender_ref, _event}
    end

    test "ignores log messages that are logged by Sentry itself", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      Logger.error("Sentry had an error", domain: [:sentry])
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      refute_receive {^sender_ref, _event}
    end
  end

  test "a logged raised exception is reported", %{
    handler_ref: handler_ref,
    sender_ref: sender_ref
  } do
    LoggerHandlerKit.Act.task_error(:exception)
    LoggerHandlerKit.Assert.assert_logged(handler_ref)

    assert_receive {^sender_ref, event}

    assert [exception] = event.exception
    assert exception.type == "RuntimeError"
    assert exception.value == "oops"
  end

  test "retrieves context from :callers", %{handler_ref: handler_ref, sender_ref: sender_ref} do
    Sentry.Context.set_extra_context(%{day_of_week: "Friday"})
    Sentry.Context.set_user_context(%{user_id: 3})

    LoggerHandlerKit.Act.task_error(:exception)
    LoggerHandlerKit.Assert.assert_logged(handler_ref)

    assert_receive {^sender_ref, event}

    assert event.user.user_id == 3
    assert event.extra.day_of_week == "Friday"
    assert [exception] = event.exception
    assert exception.type == "RuntimeError"
    assert exception.value == "oops"
  end

  describe "with a crashing GenServer" do
    test "a GenServer raising an error is reported",
         %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.genserver_crash(:exception)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert %RuntimeError{} = event.original_exception
      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"

      assert Enum.find(
               exception.stacktrace.frames,
               &(&1.function =~ "anonymous fn/0 in LoggerHandlerKit.Act.genserver_crash/1")
             )
    end

    test "a GenServer throw is reported", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.genserver_crash(:throw)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.message.formatted =~ "** (stop) bad return value: \"catch!\""
    end

    test "abnormal GenServer exit is reported", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      {:ok, pid} = LoggerHandlerKit.GenServer.start(nil)

      try do
        GenServer.call(pid, {:run, fn -> {:stop, :bad_exit, :no_state} end})
      catch
        :exit, {:bad_exit, _} -> :ok
      end

      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert event.message.message == "GenServer %s terminating: ** (stop) :bad_exit"
      assert event.message.params == [inspect(pid)]

      if System.otp_release() >= "26" do
        assert [] = event.exception
        assert [thread] = event.threads
        assert thread.stacktrace.frames == nil
        assert event.extra.genserver_state == ":no_state"
        assert event.extra.last_message =~ ~r/^\{:run, .*/
        assert event.extra.pid_which_sent_last_message == inspect(self())
        assert event.extra.genserver_state == ":no_state"
        assert event.extra.crash_reason == ":bad_exit"
      end
    end

    test "an exit while calling another GenServer is reported nicely", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      {:ok, pid} = LoggerHandlerKit.GenServer.start(nil)

      # Get a PID and make sure it's done before using it.
      {dead_pid, monitor_ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^monitor_ref, _, _, _}

      try do
        GenServer.call(pid, {:run, fn -> GenServer.call(dead_pid, :ping) end})
      catch
        :exit, {{:noproc, _}, _} -> :ok
      end

      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert event.exception == []
      assert event.extra.domain == [:otp]
      assert event.extra.logger_level == :error
      assert event.extra.logger_metadata == %{}
      assert event.extra.crash_reason =~ "{:noproc, {GenServer, :call"
      assert event.fingerprint == ["noproc", "genserver_call", ":ping"]

      assert event.message.formatted == """
             exited in: GenServer.call(#{inspect(dead_pid)}, :ping, 5000)
                 ** (EXIT) no process: the process is not alive or there's no process currently \
             associated with the given name, possibly because its application isn't started\
             """

      assert [%{stacktrace: stacktrace}] = event.threads
      assert Enum.find(stacktrace.frames, &(&1.function == "GenServer.call/3"))
    end

    test "a timeout while calling another GenServer is reported nicely", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      try do
        {:ok, pid} = LoggerHandlerKit.GenServer.start(nil)
        GenServer.call(pid, {:run, fn -> Agent.get(agent, & &1, 0) end})
      catch
        :exit, {{:timeout, _}, _} -> :ok
      end

      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert event.exception == []
      assert event.extra.domain == [:otp]
      assert event.extra.logger_level == :error
      assert event.extra.logger_metadata == %{}
      assert event.extra.crash_reason =~ "{:timeout, {GenServer, :call"
      assert ["timeout", "genserver_call", "{:get" <> _] = event.fingerprint

      assert event.message.formatted =~ "exited in: GenServer.call(#{inspect(agent)}, {:get, "

      assert [%{stacktrace: stacktrace}] = event.threads
      assert Enum.find(stacktrace.frames, &(&1.function == "GenServer.call/3"))
    end

    @tag handler_config: %{metadata: [:string, :number, :map, :list, :chardata]}
    test "includes Logger metadata for keys configured to be included", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      try do
        {:ok, pid} = LoggerHandlerKit.GenServer.start(nil)

        GenServer.call(
          pid,
          {:run,
           fn ->
             Logger.metadata(
               string: "string",
               number: 43,
               map: %{a: "b"},
               list: [1, 2, 3],
               chardata: ["π's unicode is", ?\s, [?π]]
             )

             invalid_function()
           end}
        )
      catch
        :exit, {{:function_clause, _}, _} -> :ok
      end

      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert event.extra.logger_metadata.string == "string"
      assert event.extra.logger_metadata.map == %{a: "b"}
      assert event.extra.logger_metadata.list == [1, 2, 3]
      assert event.extra.logger_metadata.number == 43
      assert event.extra.logger_metadata.chardata == "π's unicode is π"
    end

    @tag handler_config: %{metadata: []}
    test "does not include Logger metadata when disabled", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      try do
        {:ok, pid} = LoggerHandlerKit.GenServer.start(nil)

        GenServer.call(
          pid,
          {:run,
           fn ->
             Logger.metadata(
               string: "string",
               number: 43,
               map: %{a: "b"},
               list: [1, 2, 3],
               chardata: ["π's unicode is", ?\s, [?π]]
             )

             invalid_function()
           end}
        )
      catch
        :exit, {{:function_clause, _}, _} -> :ok
      end

      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert event.extra.logger_metadata == %{}
    end

    @tag handler_config: %{metadata: :all}
    test "supports :all for Logger metadata", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      try do
        {:ok, pid} = LoggerHandlerKit.GenServer.start(nil)

        GenServer.call(
          pid,
          {:run,
           fn ->
             Logger.metadata(my_string: "some string")
             invalid_function()
           end}
        )
      catch
        :exit, {{:function_clause, _}, _} -> :ok
      end

      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert event.extra.logger_metadata.my_string == "some string"
      assert event.extra.logger_metadata.domain == [:otp]
      assert is_integer(event.extra.logger_metadata.time)
      assert is_pid(event.extra.logger_metadata.pid)

      if System.otp_release() >= "26" do
        assert {%FunctionClauseError{}, _stacktrace} = event.extra.logger_metadata.crash_reason
      end

      # Make sure that all this stuff is serializable.
      assert Sentry.Client.render_event(event).extra.logger_metadata.pid =~ "#PID<"
    end

    test "bad function call causing GenServer crash is reported", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      try do
        {:ok, pid} = LoggerHandlerKit.GenServer.start(nil)

        GenServer.call(
          pid,
          {:run,
           fn ->
             Sentry.Context.add_breadcrumb(%{message: "test"})
             invalid_function()
           end}
        )
      catch
        :exit, {{:function_clause, _}, _} -> :ok
      end

      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert [%{message: "test"}] = event.breadcrumbs

      assert [exception] = event.exception

      assert exception.type == "FunctionClauseError"

      assert %{
               in_app: false,
               module: NaiveDateTime,
               context_line: nil,
               pre_context: [],
               post_context: []
             } = List.last(exception.stacktrace.frames)
    end

    test "GenServer timeout is reported", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      {:ok, pid} = LoggerHandlerKit.GenServer.start(nil)

      Task.start(fn ->
        GenServer.call(pid, {:run, fn -> Process.sleep(:infinity) end}, 0)
      end)

      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert [] = event.exception
      assert [thread] = event.threads

      assert event.message.formatted =~ "exited in: GenServer.call("
      assert event.message.formatted =~ "** (EXIT) time out"
      assert length(thread.stacktrace.frames) > 0
    end

    @tag handle_sasl_reports: true
    test "reports crashes on c:GenServer.init/1", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      LoggerHandlerKit.Act.genserver_init_crash()
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
    end

    test "reports crashes in gen_statem", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      LoggerHandlerKit.Act.gen_statem_crash()
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}

      assert [exception] = event.exception
      assert exception.type == "RuntimeError"
      assert exception.value == "oops"
    end
  end

  describe "rate limiting" do
    @tag handler_config: %{
           rate_limiting: [max_events: 2, interval: 150],
           capture_log_messages: true
         }
    test "limits logged messages", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      Logger.error("First")
      Logger.error("Second")
      Logger.error("Third")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      assert_receive {^sender_ref, %{message: %{formatted: "First"}}}
      assert_receive {^sender_ref, %{message: %{formatted: "Second"}}}
      refute_receive {^sender_ref, _event}, 100

      Process.sleep(150)
      Logger.error("Fourth")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      assert_receive {^sender_ref, %{message: %{formatted: "Fourth"}}}
    end

    @tag handler_config: %{capture_log_messages: true}
    test "without rate limiting, doesn't rate limit", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      for index <- 1..10 do
        message = "Message #{index}"
        Logger.error(message)
        LoggerHandlerKit.Assert.assert_logged(handler_ref)
        assert_receive {^sender_ref, %{message: %{formatted: ^message}}}
      end
    end

    @tag handler_config: %{
           rate_limiting: [max_events: 2, interval: 150],
           capture_log_messages: true
         }
    test "works with changing config to disable rate limiting", %{
      handler_id: handler_id,
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      assert {:ok, %{config: config}} = :logger.get_handler_config(handler_id)

      :ok =
        :logger.update_handler_config(
          handler_id,
          :config,
          put_in(config.inside_config.rate_limiting, nil)
        )

      for index <- 1..10 do
        message = "Message #{index}"
        Logger.error(message)
        LoggerHandlerKit.Assert.assert_logged(handler_ref)
        assert_receive {^sender_ref, %{message: %{formatted: ^message}}}
      end
    end

    @tag handler_config: %{capture_log_messages: true}
    test "works with changing config to enable rate limiting", %{
      handler_id: handler_id,
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      for index <- 1..10 do
        message = "Message #{index}"
        Logger.error(message)
        LoggerHandlerKit.Assert.assert_logged(handler_ref)
        assert_receive {^sender_ref, %{message: %{formatted: ^message}}}
      end

      assert {:ok, %{config: config}} = :logger.get_handler_config(handler_id)

      :ok =
        :logger.update_handler_config(
          handler_id,
          :config,
          put_in(config.inside_config.rate_limiting, max_events: 1, interval: 100)
        )

      Logger.error("RL1")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      assert_receive {^sender_ref, %{message: %{formatted: "RL1"}}}

      Logger.error("RL2")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      refute_receive {^sender_ref, _event}, 100
    end

    @tag handler_config: %{
           rate_limiting: [max_events: 2, interval: 100],
           capture_log_messages: true
         }
    test "works with changing config to update rate limiting", %{
      handler_id: handler_id,
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      assert {:ok, %{config: config}} = :logger.get_handler_config(handler_id)

      :ok =
        :logger.update_handler_config(
          handler_id,
          :config,
          put_in(config.inside_config.rate_limiting, max_events: 1, interval: 100)
        )

      Logger.error("RL1")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      assert_receive {^sender_ref, %{message: %{formatted: "RL1"}}}

      Logger.error("RL2")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      refute_receive {^sender_ref, _event}, 100
    end

    @tag handler_config: %{
           rate_limiting: [max_events: 2, interval: 100],
           capture_log_messages: true
         }
    test "works with changing config but without changing rate limiting", %{
      handler_id: handler_id,
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      assert {:ok, %{config: config}} = :logger.get_handler_config(handler_id)

      :ok =
        :logger.update_handler_config(
          handler_id,
          :config,
          put_in(config.inside_config.rate_limiting, max_events: 2, interval: 100)
        )

      Logger.error("RL1")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      assert_receive {^sender_ref, %{message: %{formatted: "RL1"}}}

      Logger.error("RL2")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      assert_receive {^sender_ref, %{message: %{formatted: "RL2"}}}

      Logger.error("RL3")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      refute_receive {^sender_ref, _event}, 100
    end
  end

  describe "discard threshold" do
    @tag handler_config: %{
           discard_threshold: 2,
           sync_threshold: nil,
           capture_log_messages: true
         },
         send_request: true
    test "discards logged messages", %{handler_ref: handler_ref, sender_ref: sender_ref} do
      Logger.error("First")
      Logger.error("Second")
      Logger.error("Third")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)
      assert_receive {^sender_ref, %{message: %{formatted: "First"}}}
      assert_receive {^sender_ref, %{message: %{formatted: "Second"}}}
      refute_receive {^sender_ref, _event}, 100
    end
  end

  @tag handler_config: %{
         sync_threshold: 2
       }
  test "cannot set discard_threshold and sync_threshold", %{handler_id: handler_id} do
    assert {:ok, %{config: config}} = :logger.get_handler_config(handler_id)

    assert {:error,
            {:callback_crashed,
             {:error,
              %ArgumentError{
                message:
                  ":sync_threshold and :discard_threshold cannot be used together, one of them must be nil"
              },
              _}}} =
             :logger.update_handler_config(
               handler_id,
               :config,
               put_in(config.inside_config.discard_threshold, 1)
             )
  end

  describe "with logger metadata as tags" do
    @tag handler_config: %{capture_log_messages: true, tags_from_metadata: [:string, :number]}
    test "includes configured Logger metadata as tags, but only if strings", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      Logger.metadata(string: "value", number: 42, other: "ignored")
      Logger.error("Testing error")
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.tags == %{string: "value"}
    end

    @tag handler_config: %{capture_log_messages: true, tags_from_metadata: []}
    test "does not include Logger metadata as tags when disabled", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      Logger.error("Testing error", string: "value", number: 42)
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.tags == %{}
    end

    @tag handler_config: %{capture_log_messages: true, tags_from_metadata: [:string, :number]}
    test "merges configured tags with explicitly set tags", %{
      handler_ref: handler_ref,
      sender_ref: sender_ref
    } do
      Logger.metadata(string: "value", number: 42)
      Logger.error("Testing error", sentry: [tags: %{explicit: "tag", number: 44}])
      LoggerHandlerKit.Assert.assert_logged(handler_ref)

      assert_receive {^sender_ref, event}
      assert event.tags == %{string: "value", number: 44, explicit: "tag"}
    end
  end

  defp invalid_function do
    # This needs to be dynamic in order to not warn with Elixir's type system
    apply(NaiveDateTime, :from_erl, [{}, {}, {}])
  end
end
