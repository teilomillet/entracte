defmodule SymphonyElixir.GitLab.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitLab.Client, as: GitLabClient

  test "fetch_coverage retrieves latest pipeline coverage from configured GitLab project" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gitlab_endpoint: "https://gitlab.example.com/api/v4/",
      gitlab_api_token: "gitlab-token",
      gitlab_project_id: "group/project"
    )

    test_pid = self()

    assert {:ok, coverage} =
             GitLabClient.fetch_coverage(%{"ref" => "main"},
               request_fun: fn url, opts ->
                 send(test_pid, {:request, url, opts})

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "id" => 287,
                      "iid" => 144,
                      "project_id" => 21,
                      "status" => "success",
                      "ref" => "main",
                      "sha" => "50f0acb",
                      "coverage" => 93.4,
                      "source" => "push",
                      "web_url" => "https://gitlab.example.com/group/project/-/pipelines/287",
                      "created_at" => "2026-04-29T12:00:00Z",
                      "updated_at" => "2026-04-29T12:02:00Z"
                    }
                  }}
               end
             )

    assert_received {:request, "https://gitlab.example.com/api/v4/projects/group%2Fproject/pipelines/latest", opts}
    assert Keyword.fetch!(opts, :headers) == [{"PRIVATE-TOKEN", "gitlab-token"}]
    assert Keyword.fetch!(opts, :receive_timeout) == 30_000
    assert Keyword.fetch!(opts, :params) == [ref: "main"]

    assert coverage == %{
             "project_id" => 21,
             "pipeline_id" => 287,
             "pipeline_iid" => 144,
             "status" => "success",
             "ref" => "main",
             "sha" => "50f0acb",
             "coverage" => 93.4,
             "source" => "push",
             "web_url" => "https://gitlab.example.com/group/project/-/pipelines/287",
             "created_at" => "2026-04-29T12:00:00Z",
             "updated_at" => "2026-04-29T12:02:00Z"
           }
  end

  test "fetch_coverage retrieves explicit pipeline coverage from input project override" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gitlab_endpoint: "https://gitlab.example.com/api/v4",
      gitlab_api_token: "gitlab-token",
      gitlab_project_id: "configured/project"
    )

    test_pid = self()

    assert {:ok, coverage} =
             GitLabClient.fetch_coverage(%{"project_id" => "override/project", "pipeline_id" => 42},
               request_fun: fn url, opts ->
                 send(test_pid, {:request, url, opts})

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "id" => 42,
                      "status" => "failed",
                      "coverage" => nil
                    }
                  }}
               end
             )

    assert_received {:request, "https://gitlab.example.com/api/v4/projects/override%2Fproject/pipelines/42", opts}
    assert Keyword.fetch!(opts, :headers) == [{"PRIVATE-TOKEN", "gitlab-token"}]
    assert Keyword.fetch!(opts, :receive_timeout) == 30_000
    refute Keyword.has_key?(opts, :params)

    assert coverage["project_id"] == "override/project"
    assert coverage["pipeline_id"] == 42
    assert coverage["status"] == "failed"
    assert coverage["coverage"] == nil
  end

  test "fetch_coverage reports missing configured auth and project" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gitlab_api_token: nil,
      gitlab_project_id: nil
    )

    assert {:error, :missing_gitlab_project_id} = GitLabClient.fetch_coverage(%{})
    assert {:error, :missing_gitlab_api_token} = GitLabClient.fetch_coverage(%{"project_id" => "group/project"})
  end

  test "fetch_coverage wraps request and status failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gitlab_api_token: "gitlab-token",
      gitlab_project_id: "group/project"
    )

    assert {:error, {:gitlab_api_request, :timeout}} =
             GitLabClient.fetch_coverage(%{}, request_fun: fn _url, _opts -> {:error, :timeout} end)

    assert {:error, {:gitlab_api_status, 404, %{"message" => "not found"}}} =
             GitLabClient.fetch_coverage(%{},
               request_fun: fn _url, _opts ->
                 {:ok, %{status: 404, body: %{"message" => "not found"}}}
               end
             )
  end
end
