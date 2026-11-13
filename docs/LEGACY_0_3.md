# Historical Spectre 0.3 integration

These examples describe the former Instance/Run integration. They are retained
for maintaining existing applications, **not as the starting architecture for
core 0.4 AgentServer applications**. Use the [0.4 migration guide](MIGRATING_TO_SPECTRE_0_4.md)
and [current README](../README.md) for the new Stack → Agent → Server lifecycle.
A `protect`/policy block below is legacy application DSL; installing a package
never supplies a 0.4 GAM host binding or end-user consent.

## Spectre Agent integration

Install Mnemonic in a Spectre Stack:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Mnemonic do
    isolate_by [:instance]
  end
end

children = [
  {Spectre.Stack.Runtime,
   stack: MyApp.AI,
   name: MyApp.AIRuntime,
   packages: [mnemonic: [data_root: "data/memory"]]},
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]
```

Spectre resolves the Engine resource through the named Stack Runtime and calls
Mnemonic through its normal memory lifecycle. `isolate_by: []` remains the
historical shared-memory default; `[:instance]` is the recommended opt-in and
fails closed when no `%Spectre.Instance.Ref{}` is available.

The full setup, isolation behavior, and direct adapter calls are documented in
[Getting started](#detailed-legacy-memory-lifecycle).



## Detailed legacy memory lifecycle

## Spectre Agent integration

Mnemonic can be installed as the memory service in a Spectre Stack:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Mnemonic do
    isolate_by [:instance]
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end

children = [
  {Spectre.Stack.Runtime,
   stack: MyApp.AI,
   name: MyApp.AIRuntime,
   packages: [mnemonic: [data_root: "data/memory"]]},
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]

Spectre.instance(
  MyApp.SpectreSupervisor,
  MyApp.Agent,
  subject,
  stack_runtime: MyApp.AIRuntime
)
```

`Spectre.Stack.Runtime` supervises the same `SpectreMnemonic.Engine` used by a
standalone application. Selecting the Stack activates
`Spectre.Mnemonic.Memory`; a second `use Spectre.Mnemonic` is not required.
The runtime name is resolved for each callback and is never persisted in a Run,
checkpoint, Journal payload, or receipt.

Spectre's normal memory callbacks then:

1. derive an opaque Mnemonic scope from the declared isolation dimensions;
2. recall memory before the Agent handles the turn;
3. persist a compact logical projection after a turn commits;
4. keep full Results, States, process handles, and adapter handles out of
   durable memory;
5. emit privacy-safe Journal outcomes containing dimension names and status,
   never memory content or subject values.

### Instance isolation

`isolate_by: []` remains the historical default and deliberately shares the
unscoped partition among every Agent and Subject using that installation. It is
not changed automatically because doing so would make 0.1.x shared memory
invisible.

`isolate_by [:instance]` is recommended for new installations. It derives the
opaque scope from `{instance_ref.schema_version, instance_ref.key}`. Agent
definition versions and Stack digests do not change that logical identity.
Missing Instance refs fail closed with:

```elixir
{:error, {:mnemonic_isolation_dimension_required, :instance}}
```

### Canonical subject isolation

If `:subject` is present in `isolate_by`, the runtime must supply an explicit
canonical `%Spectre.Subject{}`:

```elixir
subject = Spectre.Subject.new(account.id)

{:ok, memory_opts} =
  Spectre.Mnemonic.Memory.options(MyApp.Agent,
    agent: MyApp.Agent,
    subject: subject,
    input: input,
    state: state,
    stack_runtime: MyApp.AIRuntime
  )
```

The partition uses `Spectre.Subject.key/1`. Mnemonic does not infer identity
from a sender name, phone number, `Input.Source.actor_id`, or conversation id.
Different channel identities share memory only after the Subject Registry links
them and the owning Agent Instance supplies the same canonical Subject.

Missing canonical subjects fail closed with
`:mnemonic_canonical_subject_required`. Scalar identities passed explicitly by
application code are normalized through `Spectre.Subject.new/1`.

### Other isolation dimensions

- `:agent` uses canonical `Spectre.AgentRef`, so two logical Agent instances
  backed by the same module do not share memory accidentally.
- `:conversation` follows the current Run/Input origin. It is not the stable
  persistence identity of the Subject-owned Agent Instance.
- `:flow` and `:task` use the corresponding current runtime context.
- `:instance` uses the stable schema-versioned `Spectre.Instance.Ref` key and
  fails closed when only legacy Session metadata is available.

Mnemonic memory values are never stored in `%Spectre.Run{}`. Recall is resolved
again when a restored Run advances.

### Inspect the compiled installation

```elixir
{:ok, config} = Spectre.Mnemonic.config(MyApp.Agent)
config.store
config.isolate_by
config.options
```

The Stack installation owns one Engine resource. Its default `storage_id` is
derived from `{stack_owner, installation_id}`, not the complete Stack digest,
so a compatible Stack update does not silently select a fresh data directory.
