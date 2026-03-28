defmodule GoCardlessClient.Signing do
  @moduledoc """
  GoCardlessClient API request signing for Outbound Payments.

  GoCardlessClient requires ECDSA P-256 (ES256) request signatures for outbound payment
  endpoints. The signature covers the request target, date, nonce, body digest,
  and content-type headers.

  ## Setup

      # Load your private key (PEM format)
      pem = File.read!("private_key.pem")
      {:ok, signer} = GoCardlessClient.Signing.new(key_id: "your-key-id", pem: pem)

  ## Usage with the HTTP client

      {:ok, payment} = GoCardlessClient.Resources.OutboundPayments.create(client, params,
        signer: signer,
        idempotency_key: GoCardlessClient.new_idempotency_key()
      )
  """

  @type algorithm :: :ecdsa | :rsa
  @type t :: %__MODULE__{
          key_id: String.t(),
          algorithm: algorithm(),
          private_key: term()
        }

  defstruct [:key_id, :algorithm, :private_key]

  @doc """
  Creates a new `Signing` struct from a PEM-encoded private key.

  ## Options

  - `:key_id` (required) — the key ID registered in your GoCardlessClient dashboard
  - `:pem` (required) — PEM-encoded private key binary
  - `:algorithm` — `:ecdsa` (default) or `:rsa`
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) do
    key_id = Keyword.fetch!(opts, :key_id)
    pem = Keyword.fetch!(opts, :pem)
    algorithm = Keyword.get(opts, :algorithm, :ecdsa)

    case decode_private_key(pem, algorithm) do
      {:ok, private_key} ->
        {:ok, %__MODULE__{key_id: key_id, algorithm: algorithm, private_key: private_key}}

      {:error, _} = err ->
        err
    end
  end

  @doc "Like `new/1` but raises on error."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, signer} -> signer
      {:error, reason} -> raise ArgumentError, "GoCardlessClient.Signing: #{reason}"
    end
  end

  @doc """
  Generates the signing headers for an outgoing request.

  Returns `{:ok, headers}` where `headers` is a list of `{name, value}` tuples
  to merge into the request headers:

  - `"Date"` — RFC 2822 formatted UTC timestamp
  - `"Nonce"` — 32-char hex random nonce
  - `"Digest"` — `SHA-256=<hex>` of the request body
  - `"Signature"` — the full signature header string
  """
  @spec sign_headers(t(), String.t(), String.t(), binary()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def sign_headers(%__MODULE__{} = signer, method, path, body) when is_binary(body) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    date = format_date()
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    content_type = "application/json"

    signature_base =
      [
        "(request-target): #{String.downcase(method)} #{path}",
        "date: #{date}",
        "nonce: #{nonce}",
        "digest: SHA-256=#{digest}",
        "content-type: #{content_type}"
      ]
      |> Enum.join("\n")

    case compute_signature(signer, signature_base) do
      {:ok, sig_b64} ->
        # Build the Signature header as a single interpolated string.
        # Splitting across ~s() sigils with string concatenation causes syntax
        # errors in Elixir when sigil content contains reserved words.
        sig_header =
          "keyId=\"#{signer.key_id}\"," <>
            "algorithm=\"#{algorithm_name(signer)}\"," <>
            "headers=\"(request-target) date nonce digest content-type\"," <>
            "signature=\"#{sig_b64}\""

        {:ok,
         [
           {"Date", date},
           {"Nonce", nonce},
           {"Digest", "SHA-256=#{digest}"},
           {"Signature", sig_header}
         ]}

      {:error, _} = err ->
        err
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp decode_private_key(pem, :ecdsa) do
    with [entry] <- :public_key.pem_decode(pem),
         {:ECPrivateKey, _, _, _, _, _} = key <- :public_key.pem_entry_decode(entry) do
      {:ok, key}
    else
      _ -> {:error, "Could not decode ECDSA private key from PEM"}
    end
  end

  defp decode_private_key(pem, :rsa) do
    with [entry] <- :public_key.pem_decode(pem),
         {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key <-
           :public_key.pem_entry_decode(entry) do
      {:ok, key}
    else
      _ -> {:error, "Could not decode RSA private key from PEM"}
    end
  end

  defp compute_signature(%{algorithm: :ecdsa, private_key: key}, data) do
    digest = :crypto.hash(:sha256, data)
    sig = :public_key.sign(digest, :sha256, key, [{:ecdsa_padding, :der}]) |> Base.encode64()
    {:ok, sig}
  rescue
    e -> {:error, "ECDSA signing failed: #{inspect(e)}"}
  end

  defp compute_signature(%{algorithm: :rsa, private_key: key}, data) do
    digest = :crypto.hash(:sha256, data)
    sig = :public_key.sign(digest, :sha256, key) |> Base.encode64()
    {:ok, sig}
  rescue
    e -> {:error, "RSA signing failed: #{inspect(e)}"}
  end

  defp algorithm_name(%{algorithm: :ecdsa}), do: "ecdsa-p256-sha256"
  defp algorithm_name(%{algorithm: :rsa}), do: "rsa-sha256"

  defp format_date do
    {{y, m, d}, {h, min, s}} = :calendar.universal_time()
    day_of_week = :calendar.day_of_the_week(y, m, d)

    day_name =
      Enum.at(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], day_of_week - 1)

    month_name =
      Enum.at(
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        m - 1
      )

    d_str = String.pad_leading(to_string(d), 2, "0")
    h_str = String.pad_leading(to_string(h), 2, "0")
    min_str = String.pad_leading(to_string(min), 2, "0")
    s_str = String.pad_leading(to_string(s), 2, "0")

    "#{day_name}, #{d_str} #{month_name} #{y} #{h_str}:#{min_str}:#{s_str} GMT"
  end
end
