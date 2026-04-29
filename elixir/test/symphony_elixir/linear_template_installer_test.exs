defmodule SymphonyElixir.LinearTemplateInstallerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LinearTemplateInstaller

  test "creates the default Linear issue template when no matching template exists" do
    parent = self()

    assert {:ok, [result]} =
             LinearTemplateInstaller.install([], deps(parent, templates: []))

    assert result.action == :created
    assert result.template.id == "template-1"
    assert result.context.team_key == "ENG"
    assert_received {:created, %{input: input}}
    assert input.teamId == "team-1"
    assert input.type == "issue"
    assert input.name == LinearTemplateInstaller.default_template_name()
    assert input.templateData.description =~ "## Acceptance Criteria"
    assert input.templateData.description =~ "## Validation"
  end

  test "loads profile env files when profile is provided" do
    parent = self()

    assert {:ok, [%{action: :created}]} =
             LinearTemplateInstaller.install([profile: "client-a"], deps(parent, templates: []))

    assert_received {:load_env_file, env_file}
    assert Path.basename(env_file) == ".env.client-a"
    refute_received {:load_env_file_if_present, _path}
  end

  test "updates an existing matching template instead of creating a duplicate" do
    parent = self()

    templates = [
      %{
        "id" => "template-1",
        "type" => "issue",
        "name" => LinearTemplateInstaller.default_template_name(),
        "team" => %{"id" => "team-1"}
      }
    ]

    assert {:ok, [result]} =
             LinearTemplateInstaller.install(
               [name: LinearTemplateInstaller.default_template_name()],
               deps(parent, templates: templates)
             )

    assert result.action == :updated
    assert result.template.id == "template-1"
    assert_received {:updated, %{id: "template-1", input: input}}
    refute_received {:created, _variables}
    assert input.name == LinearTemplateInstaller.default_template_name()
  end

  test "leaves an existing template unchanged when updates are disabled" do
    parent = self()

    templates = [
      %{
        "id" => "template-1",
        "type" => "issue",
        "name" => LinearTemplateInstaller.default_template_name(),
        "team" => %{"id" => "team-1"}
      }
    ]

    assert {:ok, [result]} =
             LinearTemplateInstaller.install(
               [update_existing: false],
               deps(parent, templates: templates)
             )

    assert result.action == :unchanged
    assert result.template.id == "template-1"
    refute_received {:updated, _variables}
    refute_received {:created, _variables}
  end

  test "normalizes existing templates when Linear returns templateData as encoded JSON" do
    parent = self()

    templates = [
      %{
        "id" => "template-1",
        "type" => "issue",
        "name" => LinearTemplateInstaller.default_template_name(),
        "description" => "Agent task template",
        "templateData" => Jason.encode!(%{"description" => "## Goal\nDo the work."}),
        "team" => %{"id" => "team-1"}
      }
    ]

    assert {:ok, [result]} =
             LinearTemplateInstaller.install(
               [update_existing: false],
               deps(parent, templates: templates)
             )

    assert result.action == :unchanged
    assert result.template.description == "Agent task template"
    assert result.template.body == "## Goal\nDo the work."
  end

  test "does not crash when Linear returns rich templateData without markdown description" do
    parent = self()

    templates = [
      %{
        "id" => "template-1",
        "type" => "issue",
        "name" => LinearTemplateInstaller.default_template_name(),
        "templateData" => Jason.encode!(%{"descriptionData" => %{"type" => "doc", "content" => []}}),
        "team" => %{"id" => "team-1"}
      }
    ]

    assert {:ok, [result]} =
             LinearTemplateInstaller.install(
               [update_existing: false],
               deps(parent, templates: templates)
             )

    assert result.action == :unchanged
    assert result.template.body == nil
  end

  test "installs templates for every configured project team" do
    parent = self()

    project_responses = %{
      "project-a" => {:ok, %{"data" => %{"projects" => %{"nodes" => [project("project-a", team("team-1", "ENG"))]}}}},
      "project-b" => {:ok, %{"data" => %{"projects" => %{"nodes" => [project("project-b", team("team-2", "OPS"))]}}}}
    }

    assert {:ok, results} =
             LinearTemplateInstaller.install(
               [],
               deps(parent,
                 templates: [],
                 project_responses: project_responses,
                 settings: fn -> %{tracker: %{project_slugs: ["project-a", "project-b"]}} end
               )
             )

    assert Enum.map(results, & &1.context.team_key) == ["ENG", "OPS"]
    assert_received {:created, %{input: %{teamId: "team-1"}}}
    assert_received {:created, %{input: %{teamId: "team-2"}}}
  end

  test "returns project lookup errors" do
    failing_deps =
      deps(self(),
        project_response: {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}}
      )

    assert {:error, :linear_project_not_found} = LinearTemplateInstaller.install([], failing_deps)
  end

  defp deps(parent, opts) do
    project_response =
      Keyword.get(opts, :project_response, {:ok, %{"data" => %{"projects" => %{"nodes" => [project()]}}}})

    project_responses = Keyword.get(opts, :project_responses, %{})

    templates = Keyword.get(opts, :templates, [])

    %{
      load_env_file: fn path ->
        send(parent, {:load_env_file, path})
        :ok
      end,
      load_env_file_if_present: fn path ->
        send(parent, {:load_env_file_if_present, path})
        :ok
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow, path})
        :ok
      end,
      validate_config: fn -> :ok end,
      settings: Keyword.get(opts, :settings, fn -> %{tracker: %{project_slug: "project-slug", project_slugs: ["project-slug"]}} end),
      ensure_req_started: fn -> {:ok, [:req]} end,
      linear_graphql: fn query, variables ->
        cond do
          String.contains?(query, "projects") ->
            Map.get(project_responses, variables.slug, project_response)

          String.contains?(query, "templates") ->
            {:ok, %{"data" => %{"templates" => templates}}}

          String.contains?(query, "templateCreate") ->
            send(parent, {:created, variables})
            {:ok, %{"data" => %{"templateCreate" => %{"success" => true, "template" => %{"id" => "template-1", "name" => variables.input.name}}}}}

          String.contains?(query, "templateUpdate") ->
            send(parent, {:updated, variables})
            {:ok, %{"data" => %{"templateUpdate" => %{"success" => true, "template" => %{"id" => variables.id, "name" => variables.input.name}}}}}
        end
      end
    }
  end

  defp project do
    project("project-slug", team("team-1", "ENG"))
  end

  defp project(slug, team) do
    %{
      "id" => "project-#{slug}",
      "name" => "Project #{slug}",
      "slugId" => slug,
      "teams" => %{
        "nodes" => [
          team
        ]
      }
    }
  end

  defp team(id, key), do: %{"id" => id, "key" => key, "name" => "Team #{key}"}
end
