content = File.read!("lib/viche/agents.ex")

content =
  String.replace(
    content,
    "@spec user_owns_agent?(String.t() | nil, String.t()) :: boolean()",
    "@spec user_owns_agent?(String.t() | nil, String.t()) :: boolean() | {:error, :not_found}"
  )

File.write!("lib/viche/agents.ex", content)
