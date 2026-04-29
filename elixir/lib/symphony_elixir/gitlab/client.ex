defmodule SymphonyElixir.GitLab.Client do
  @moduledoc """
  Minimal GitLab REST client for coverage primitives exposed to Codex sessions.
  """

  require Logger

  alias SymphonyElixir.Config

  @max_error_body_log_bytes 1_000

  @type coverage_params :: %{
          optional(String.t()) => String.t() | integer()
        }

  @spec fetch_coverage(coverage_params(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_coverage(params, opts \\ []) when is_map(params) and is_list(opts) do
    settings = Config.settings!().gitlab
    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    with {:ok, project_id} <- resolve_project_id(params, settings),
         {:ok, endpoint} <- resolve_endpoint(settings),
         {:ok, api_token} <- resolve_api_token(settings),
         {:ok, url, request_opts} <- build_coverage_request(endpoint, project_id, params, api_token) do
      case request_fun.(url, request_opts) do
        {:ok, response} -> handle_response(response, project_id)
        {:error, reason} -> {:error, {:gitlab_api_request, reason}}
      end
    end
  rescue
    error in ArgumentError ->
      {:error, {:invalid_config, Exception.message(error)}}
  end

  defp resolve_project_id(params, settings) do
    case normalize_non_empty_string(Map.get(params, "project_id") || settings.project_id) do
      nil -> {:error, :missing_gitlab_project_id}
      project_id -> {:ok, project_id}
    end
  end

  defp resolve_endpoint(settings) do
    case normalize_non_empty_string(settings.endpoint) do
      nil -> {:error, :missing_gitlab_endpoint}
      endpoint -> {:ok, String.trim_trailing(endpoint, "/")}
    end
  end

  defp resolve_api_token(settings) do
    case normalize_non_empty_string(settings.api_token) do
      nil -> {:error, :missing_gitlab_api_token}
      api_token -> {:ok, api_token}
    end
  end

  defp build_coverage_request(endpoint, project_id, params, api_token) do
    headers = [{"PRIVATE-TOKEN", api_token}]
    request_opts = [headers: headers, receive_timeout: 30_000]
    encoded_project_id = URI.encode_www_form(project_id)

    case Map.get(params, "pipeline_id") do
      nil ->
        query =
          case normalize_non_empty_string(Map.get(params, "ref")) do
            nil -> []
            ref -> [ref: ref]
          end

        {:ok, "#{endpoint}/projects/#{encoded_project_id}/pipelines/latest", Keyword.put(request_opts, :params, query)}

      pipeline_id ->
        {:ok, "#{endpoint}/projects/#{encoded_project_id}/pipelines/#{pipeline_id}", request_opts}
    end
  end

  defp handle_response(%Req.Response{status: 200, body: body}, project_id) when is_map(body) do
    {:ok, normalize_pipeline(body, project_id)}
  end

  defp handle_response(%{status: 200, body: body}, project_id) when is_map(body) do
    {:ok, normalize_pipeline(body, project_id)}
  end

  defp handle_response(%Req.Response{} = response, _project_id) do
    Logger.error("GitLab coverage request failed status=#{response.status} body=#{safe_body(response.body)}")
    {:error, {:gitlab_api_status, response.status, response.body}}
  end

  defp handle_response(%{status: status, body: body}, _project_id) when is_integer(status) do
    Logger.error("GitLab coverage request failed status=#{status} body=#{safe_body(body)}")
    {:error, {:gitlab_api_status, status, body}}
  end

  defp handle_response(response, _project_id) do
    {:error, {:gitlab_api_response, response}}
  end

  defp normalize_pipeline(body, project_id) do
    %{
      "project_id" => body["project_id"] || project_id,
      "pipeline_id" => body["id"],
      "pipeline_iid" => body["iid"],
      "status" => body["status"],
      "ref" => body["ref"],
      "sha" => body["sha"],
      "coverage" => body["coverage"],
      "source" => body["source"],
      "web_url" => body["web_url"],
      "created_at" => body["created_at"],
      "updated_at" => body["updated_at"]
    }
  end

  defp normalize_non_empty_string(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_non_empty_string(_value), do: nil

  defp safe_body(body) do
    body
    |> inspect(limit: 50, printable_limit: @max_error_body_log_bytes)
    |> String.slice(0, @max_error_body_log_bytes)
  end
end
