defmodule SpectreMnemonic.Integration.ContextHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.QueryContext

  @namespace "spectre_mnemonic_test"

  test "identity resolves string-keyed records and metadata" do
    assert Identity.namespace(%{"namespace" => @namespace}) == @namespace

    assert Identity.namespace(%{"metadata" => %{"namespace" => @namespace}}) == @namespace

    assert Identity.namespace(%{"namespace" => @namespace, namespace: nil}) == @namespace
  end

  test "identity rejects missing, conflicting, and multi-scope contexts" do
    assert {:error, {:namespace_mismatch, @namespace, "other"}} =
             Identity.fetch_namespace(namespace: "other")

    assert {:error, :namespace_required} = Identity.fetch_namespace(namespace: "  ")
    assert {:error, :multiple_scopes_not_allowed} = Identity.fetch_namespace(scopes: :all)

    original = Application.get_env(:spectre_mnemonic, :namespace)
    on_exit(fn -> Application.put_env(:spectre_mnemonic, :namespace, original) end)
    Application.delete_env(:spectre_mnemonic, :namespace)

    assert {:error, :namespace_required} = Identity.configured_namespace()

    assert_raise ArgumentError, ~r/requires config/, fn ->
      Identity.namespace!()
    end

    Application.put_env(:spectre_mnemonic, :namespace, original)

    assert_raise ArgumentError, ~r/exactly one :scope/, fn ->
      Identity.namespace!(scopes: [:one, :two])
    end

    assert_raise ArgumentError, ~r/does not match configured namespace/, fn ->
      Identity.namespace!(namespace: "other")
    end
  end

  test "identity generates UUIDv7 ids and derives stable ids from them" do
    source = Identity.generate("sig")
    derived = Identity.derived("mom", source)

    assert source =~
             ~r/^sig_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert String.replace_prefix(derived, "mom_", "") == String.replace_prefix(source, "sig_", "")
    assert Identity.derived("mom", "legacy-id") =~ ~r/^mom_.*-7[0-9a-f]{3}-/
  end

  test "scope detects conflicting atom and string declarations at every level" do
    alpha = {:tenant, "alpha"}
    beta = {:tenant, "beta"}

    conflicting_top = %{
      "scope" => beta,
      namespace: @namespace,
      scope: alpha,
      metadata: %{namespace: @namespace, scope: alpha}
    }

    refute Scope.consistent?(conflicting_top)

    assert {:error, :inconsistent_memory_context} =
             Scope.validate_context(conflicting_top, @namespace, alpha)

    conflicting_metadata = %{
      "metadata" => %{"namespace" => @namespace, "scope" => beta},
      namespace: @namespace,
      scope: alpha,
      metadata: %{namespace: @namespace, scope: alpha}
    }

    refute Scope.consistent?(conflicting_metadata)

    conflicting_nested = %{
      "payload" => %{"namespace" => @namespace, "scope" => beta},
      namespace: @namespace,
      scope: alpha,
      payload: %{namespace: @namespace, scope: alpha}
    }

    assert {:error, {:scope_mismatch, ^alpha, ^beta}} =
             Scope.validate_context(conflicting_nested, @namespace, alpha)
  end

  test "scope assignment fills nil placeholders but rejects foreign partitions" do
    alpha = {:tenant, "alpha"}
    beta = {:tenant, "beta"}

    assert :ok =
             Scope.validate_assignable_context(
               %{namespace: nil, scope: nil, metadata: %{"scope" => alpha}},
               @namespace,
               alpha
             )

    assert {:error, {:scope_mismatch, ^alpha, ^beta}} =
             Scope.validate_assignable_context(
               %{"namespace" => @namespace, "scope" => beta},
               @namespace,
               alpha
             )

    memory = %{"metadata" => %{"namespace" => @namespace, "scope" => alpha}}
    assert Scope.scope(memory) == alpha
    assert Scope.match?(memory, scope: alpha)
    refute Scope.match?(memory, scope: beta)
    assert Scope.match_namespace?(memory, scope: beta)
    refute Scope.match?("not-memory", scope: alpha)
  end

  test "query contexts are immutable partition contracts and reuse one embedding" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.CountingAdapter)
    alpha = {:tenant, "alpha"}
    beta = {:tenant, "beta"}

    assert {:ok, context} =
             QueryContext.new("Deploy Alice deploy", scope: alpha, test_pid: self())

    assert_receive {:embedded, "Deploy Alice deploy"}
    assert context.namespace == @namespace
    assert context.scope == alpha
    assert context.scopes == [alpha]
    assert context.keywords == ["deploy", "alice"]
    assert context.entities == ["Deploy", "Alice"]

    assert {:ok, reused} = QueryContext.ensure(context, limit: 3)
    assert reused.opts[:limit] == 3
    refute_receive {:embedded, _input}

    assert {:error, {:query_context_scope_mismatch, [^beta], [^alpha]}} =
             context
             |> Map.put(:scope, beta)
             |> QueryContext.ensure(scope: alpha)

    assert {:error, {:query_context_scope_mismatch, [^beta], [^alpha]}} =
             context
             |> Map.put(:scopes, [beta])
             |> QueryContext.ensure(scope: alpha)

    assert {:error, {:query_context_namespace_mismatch, "other", @namespace}} =
             context
             |> Map.put(:namespace, "other")
             |> QueryContext.ensure(scope: alpha)

    assert QueryContext.text(context) == "Deploy Alice deploy"
    assert QueryContext.text("plain") == "plain"
    assert QueryContext.text(%{query: :value}) == "%{query: :value}"
  end

  test "query context creation rejects deprecated multi-scope input before embedding" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.CountingAdapter)

    assert {:error, :multiple_scopes_not_allowed} =
             QueryContext.new("private", scopes: :all, test_pid: self())

    refute_receive {:embedded, _input}
  end

  defmodule CountingAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    @impl SpectreMnemonic.Embedding.Adapter
    def embed(input, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:embedded, input})
      {:ok, [1.0, 0.0]}
    end
  end
end
