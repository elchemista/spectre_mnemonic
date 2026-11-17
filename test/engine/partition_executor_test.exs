defmodule SpectreMnemonic.Engine.PartitionExecutorTest do
  use ExUnit.Case, async: false

  alias SpectreMnemonic.Engine.PartitionExecutor

  test "idle executors release their process and expired wall-clock deadlines do not run work" do
    parent = self()
    key = partition_key({:idle_partition, make_ref()})

    request =
      Task.async(fn ->
        PartitionExecutor.trans(
          key,
          fn ->
            send(parent, {:idle_executor_ready, self()})

            receive do
              :release_idle_executor -> {:ok, self()}
            after
              5_000 -> flunk("idle executor was not released")
            end
          end,
          idle_timeout: 10
        )
      end)

    assert_receive {:idle_executor_ready, first}, 1_000
    monitor = Process.monitor(first)
    send(first, :release_idle_executor)
    assert {:ok, ^first} = Task.await(request)
    assert_receive {:DOWN, ^monitor, :process, ^first, :normal}, 1_000
    wait_for_registry_cleanup(key)
    assert {:ok, second} = PartitionExecutor.trans(key, fn -> {:ok, self()} end)
    refute second == first

    assert {:error, :mnemonic_deadline_exceeded} =
             PartitionExecutor.trans(key, fn -> flunk("expired work executed") end,
               deadline: DateTime.add(DateTime.utc_now(), -1, :second)
             )
  end

  test "serializes one partition while allowing different partitions to run" do
    parent = self()
    first_key = partition_key({:test_partition, make_ref()})
    second_key = partition_key({:test_partition, make_ref()})

    first =
      Task.async(fn ->
        PartitionExecutor.trans(first_key, fn ->
          send(parent, {:entered, :first, self()})
          receive do: (:release_first -> :first_done)
        end)
      end)

    assert_receive {:entered, :first, first_executor}

    queued =
      Task.async(fn ->
        PartitionExecutor.trans(first_key, fn ->
          send(parent, {:entered, :queued, self()})
          :queued_done
        end)
      end)

    concurrent =
      Task.async(fn ->
        PartitionExecutor.trans(second_key, fn ->
          send(parent, {:entered, :concurrent, self()})
          :concurrent_done
        end)
      end)

    assert_receive {:entered, :concurrent, concurrent_executor}
    refute first_executor == concurrent_executor
    refute_receive {:entered, :queued, _pid}, 50

    send(first_executor, :release_first)
    assert :first_done = Task.await(first)
    assert_receive {:entered, :queued, ^first_executor}
    assert :queued_done = Task.await(queued)
    assert :concurrent_done = Task.await(concurrent)
  end

  test "rejects admission beyond the configured queue bound" do
    parent = self()
    key = partition_key({:bounded_partition, make_ref()})
    opts = [max_partition_queue: 1]

    running =
      Task.async(fn ->
        PartitionExecutor.trans(
          key,
          fn ->
            send(parent, {:running, self()})
            receive do: (:release -> :ok)
          end,
          opts
        )
      end)

    assert_receive {:running, executor}

    queued =
      Task.async(fn ->
        PartitionExecutor.trans(key, fn -> :queued end, opts)
      end)

    wait_for_queue(executor, 1)

    assert {:error, {:queue_full, :partition}} =
             PartitionExecutor.trans(key, fn -> :never end, opts)

    send(executor, :release)
    assert :ok = Task.await(running)
    assert :queued = Task.await(queued)
  end

  test "deadline kills the executor so timed-out work cannot continue" do
    parent = self()
    key = partition_key({:deadline_partition, make_ref()})

    task =
      Task.async(fn ->
        PartitionExecutor.trans(
          key,
          fn ->
            send(parent, {:started, self()})
            Process.sleep(:infinity)
            send(parent, :stale_completion)
          end,
          partition_timeout: 50
        )
      end)

    assert_receive {:started, old_executor}
    assert {:error, :mnemonic_deadline_exceeded} = Task.await(task, 1_000)
    refute Process.alive?(old_executor)
    refute_receive :stale_completion, 50

    assert {:ok, new_executor} =
             PartitionExecutor.trans(key, fn -> {:ok, self()} end, partition_timeout: 1_000)

    refute old_executor == new_executor
  end

  defp wait_for_queue(executor, minimum) do
    case Process.info(executor, :message_queue_len) do
      {:message_queue_len, length} when length >= minimum ->
        :ok

      _other ->
        Process.sleep(1)
        wait_for_queue(executor, minimum)
    end
  end

  defp wait_for_registry_cleanup(key, attempts \\ 1_000)
  defp wait_for_registry_cleanup(_key, 0), do: flunk("retired executor remained registered")

  defp wait_for_registry_cleanup(key, attempts) do
    case Registry.lookup(SpectreMnemonic.Engine.PartitionRegistry, {:partition, key}) do
      [] ->
        :ok

      _entry ->
        Process.sleep(1)
        wait_for_registry_cleanup(key, attempts - 1)
    end
  end

  defp partition_key(scope) do
    {:ok, runtime} = SpectreMnemonic.Engine.resolve(SpectreMnemonic.DefaultEngine)
    {:memory_partition, runtime.config.ref, runtime.config.internal_namespace, scope}
  end
end
