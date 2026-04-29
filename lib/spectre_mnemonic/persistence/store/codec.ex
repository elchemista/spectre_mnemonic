defmodule SpectreMnemonic.Persistence.Store.Codec do
  @moduledoc """
  JSON-safe codec helpers for store adapters.

  SQL/document adapters can use this module to persist arbitrary
  `%SpectreMnemonic.Persistence.Store.Record{}` envelopes without hand-rolling
  serialization for structs, binaries, atoms, and DateTimes. The encoded map is
  safe to put in JSONB while preserving the exact Erlang term for replay.
  """

  alias SpectreMnemonic.Persistence.Store.Record

  @codec "erlang-term-base64"
  @version 1

  @doc "Encodes a persistent-memory record into a JSON-safe map."
  @spec encode_record(Record.t()) :: map()
  def encode_record(%Record{} = record) do
    %{
      "codec" => @codec,
      "version" => @version,
      "record" => encode_term(record),
      "id" => record.id,
      "family" => Atom.to_string(record.family),
      "operation" => Atom.to_string(record.operation),
      "dedupe_key" => record.dedupe_key,
      "source_event_id" => record.source_event_id,
      "inserted_at" => DateTime.to_iso8601(record.inserted_at)
    }
  end

  @doc "Decodes a map produced by `encode_record/1`."
  @spec decode_record(map()) :: {:ok, Record.t()} | {:error, term()}
  def decode_record(%{"codec" => @codec, "version" => @version, "record" => encoded}) do
    case decode_term(encoded) do
      {:ok, %Record{} = record} -> {:ok, record}
      {:ok, other} -> {:error, {:invalid_record_term, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_record(%{codec: @codec, version: @version, record: encoded}) do
    decode_record(%{"codec" => @codec, "version" => @version, "record" => encoded})
  end

  def decode_record(other), do: {:error, {:unsupported_record_codec, other}}

  @doc "Encodes any Erlang term as base64."
  @spec encode_term(term()) :: binary()
  def encode_term(term) do
    term
    |> :erlang.term_to_binary([:compressed])
    |> Base.encode64()
  end

  @doc "Decodes a term encoded by `encode_term/1`."
  @spec decode_term(binary()) :: {:ok, term()} | {:error, term()}
  def decode_term(encoded) when is_binary(encoded) do
    {:ok, encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])}
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  def decode_term(other), do: {:error, {:invalid_encoded_term, other}}
end
