defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{GitLab, Linear}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @gitlab_coverage_tool "gitlab_coverage"
  @gitlab_coverage_description """
  Retrieve normalized GitLab pipeline coverage and status using Symphony's configured GitLab auth.
  """
  @gitlab_coverage_input_properties %{
    "project_id" => %{
      "type" => ["string", "integer"],
      "description" => "Optional positive GitLab project ID or namespace/project path. Defaults to gitlab.project_id."
    },
    "pipeline_id" => %{
      "type" => ["integer", "string"],
      "description" => "Optional GitLab pipeline ID. When omitted, the latest pipeline endpoint is used."
    },
    "ref" => %{
      "type" => "string",
      "description" => "Optional branch or tag ref for the latest pipeline lookup."
    }
  }
  @gitlab_coverage_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => @gitlab_coverage_input_properties
  }
  @gitlab_coverage_allowed_arguments Map.keys(@gitlab_coverage_input_properties)

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @gitlab_coverage_tool ->
        execute_gitlab_coverage(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @gitlab_coverage_tool,
        "description" => @gitlab_coverage_description,
        "inputSchema" => @gitlab_coverage_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Linear.Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_gitlab_coverage(arguments, opts) do
    gitlab_client = Keyword.get(opts, :gitlab_client, &GitLab.Client.fetch_coverage/2)

    with {:ok, params} <- normalize_gitlab_coverage_arguments(arguments),
         {:ok, response} <- gitlab_client.(params, []) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(gitlab_tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_gitlab_coverage_arguments(arguments) when is_map(arguments) do
    normalized = normalize_argument_keys(arguments)

    with :ok <- reject_unknown_gitlab_coverage_arguments(normalized),
         {:ok, normalized} <- normalize_gitlab_coverage_pipeline_id(normalized),
         :ok <- reject_ambiguous_gitlab_coverage_target(normalized),
         :ok <- validate_optional_gitlab_coverage_string(normalized, "project_id"),
         :ok <- validate_optional_gitlab_coverage_string(normalized, "ref") do
      {:ok, normalized}
    end
  end

  defp normalize_gitlab_coverage_arguments(_arguments), do: {:error, :invalid_gitlab_arguments}

  defp normalize_argument_keys(arguments) do
    Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
  end

  defp reject_unknown_gitlab_coverage_arguments(arguments) do
    case arguments |> Map.keys() |> Enum.reject(&(&1 in @gitlab_coverage_allowed_arguments)) do
      [] -> :ok
      unknown -> {:error, {:unknown_gitlab_arguments, unknown}}
    end
  end

  defp normalize_gitlab_coverage_pipeline_id(arguments) do
    case Map.get(arguments, "pipeline_id") do
      nil ->
        {:ok, arguments}

      id when is_integer(id) and id > 0 ->
        {:ok, Map.put(arguments, "pipeline_id", id)}

      id when is_binary(id) ->
        case Integer.parse(String.trim(id)) do
          {parsed, ""} when parsed > 0 -> {:ok, Map.put(arguments, "pipeline_id", parsed)}
          _ -> {:error, :invalid_gitlab_pipeline_id}
        end

      _ ->
        {:error, :invalid_gitlab_pipeline_id}
    end
  end

  defp reject_ambiguous_gitlab_coverage_target(%{"pipeline_id" => _pipeline_id, "ref" => ref})
       when is_binary(ref) do
    if String.trim(ref) == "" do
      :ok
    else
      {:error, :ambiguous_gitlab_coverage_target}
    end
  end

  defp reject_ambiguous_gitlab_coverage_target(_arguments), do: :ok

  defp validate_optional_gitlab_coverage_string(arguments, key) do
    case Map.get(arguments, key) do
      nil ->
        :ok

      value when is_integer(value) and key == "project_id" and value > 0 ->
        :ok

      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:invalid_gitlab_argument, key}}
        else
          :ok
        end

      _ ->
        {:error, {:invalid_gitlab_argument, key}}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp gitlab_tool_error_payload(:missing_gitlab_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitLab auth. Set `gitlab.api_token` in `WORKFLOW.md` or export `GITLAB_API_TOKEN`."
      }
    }
  end

  defp gitlab_tool_error_payload(:missing_gitlab_project_id) do
    %{
      "error" => %{
        "message" => "Symphony is missing a GitLab project. Provide `project_id` to `gitlab_coverage`, set `gitlab.project_id`, or export `GITLAB_PROJECT_ID`."
      }
    }
  end

  defp gitlab_tool_error_payload(:missing_gitlab_endpoint) do
    %{
      "error" => %{
        "message" => "Symphony is missing a GitLab API endpoint. Set `gitlab.endpoint` in `WORKFLOW.md` or export `GITLAB_API_ENDPOINT`."
      }
    }
  end

  defp gitlab_tool_error_payload(:invalid_gitlab_arguments) do
    %{
      "error" => %{
        "message" => "`gitlab_coverage` expects an object with optional `project_id`, `pipeline_id`, and `ref` fields."
      }
    }
  end

  defp gitlab_tool_error_payload(:invalid_gitlab_pipeline_id) do
    %{
      "error" => %{
        "message" => "`gitlab_coverage.pipeline_id` must be a positive integer when provided."
      }
    }
  end

  defp gitlab_tool_error_payload(:ambiguous_gitlab_coverage_target) do
    %{
      "error" => %{
        "message" => "`gitlab_coverage` accepts either `pipeline_id` or `ref`, not both."
      }
    }
  end

  defp gitlab_tool_error_payload({:invalid_gitlab_argument, "project_id"}) do
    %{
      "error" => %{
        "message" => "`gitlab_coverage.project_id` must be a positive integer or non-empty string when provided."
      }
    }
  end

  defp gitlab_tool_error_payload({:invalid_gitlab_argument, key}) do
    %{
      "error" => %{
        "message" => "`gitlab_coverage.#{key}` must be a non-empty string when provided."
      }
    }
  end

  defp gitlab_tool_error_payload({:unknown_gitlab_arguments, unknown}) do
    %{
      "error" => %{
        "message" => "`gitlab_coverage` received unsupported argument(s): #{Enum.join(unknown, ", ")}."
      }
    }
  end

  defp gitlab_tool_error_payload({:gitlab_api_status, status, body}) do
    %{
      "error" => %{
        "message" => "GitLab coverage request failed with HTTP #{status}.",
        "status" => status,
        "body" => body
      }
    }
  end

  defp gitlab_tool_error_payload({:gitlab_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitLab coverage request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp gitlab_tool_error_payload({:gitlab_api_response, response}) do
    %{
      "error" => %{
        "message" => "GitLab coverage request returned an unexpected response shape.",
        "response" => inspect(response)
      }
    }
  end

  defp gitlab_tool_error_payload({:invalid_config, message}) do
    %{
      "error" => %{
        "message" => "Symphony GitLab configuration is invalid.",
        "reason" => message
      }
    }
  end

  defp gitlab_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "GitLab coverage tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
