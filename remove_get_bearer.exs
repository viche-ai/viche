content = File.read!("lib/viche_web/plugs/api_auth.ex")

content =
  String.replace(
    content,
    "  defp get_bearer_token(conn) do\n    case get_req_header(conn, \"authorization\") do\n      [\"Bearer \" <> token] -> String.trim(token)\n      _ -> nil\n    end\n  end\n",
    ""
  )

File.write!("lib/viche_web/plugs/api_auth.ex", content)
