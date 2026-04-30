defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixir.Tracker.Project

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert {:ok, []} = SymphonyElixir.Tracker.list_projects()
    assert {:ok, %{}} = SymphonyElixir.Tracker.bootstrap_env_entries([%Project{slug: "ignored"}])
    assert {:ok, []} = SymphonyElixir.Tracker.install_labels()
    assert {:ok, []} = SymphonyElixir.Tracker.install_workflow_states()
    assert {:ok, []} = SymphonyElixir.Tracker.install_issue_templates()
    assert {:ok, []} = SymphonyElixir.Tracker.install_views()
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "linear adapter exposes tracker setup callbacks" do
    previous_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
    end)

    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok,
       %{
         "data" => %{
           "projects" => %{
             "nodes" => [
               %{"id" => "ignored", "name" => "Ignored"},
               %{
                 "id" => "project-b",
                 "name" => "Beta",
                 "slugId" => "beta",
                 "url" => "https://linear.app/project/beta",
                 "teams" => %{"nodes" => []}
               },
               %{
                 "id" => "project-a",
                 "name" => "Alpha",
                 "slugId" => "alpha",
                 "url" => "https://linear.app/project/alpha",
                 "teams" => %{"nodes" => [%{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}]}
               }
             ]
           }
         }
       }}
    )

    assert {:ok, [alpha, beta]} = Adapter.list_projects()
    assert alpha.slug == "alpha"
    assert alpha.team_key == "ENG"
    assert alpha.metadata.provider == :linear
    assert beta.slug == "beta"
    assert beta.team_id == nil

    assert_receive {:graphql_called, project_query, %{first: 100}}
    assert project_query =~ "SymphonyBootstrapProjects"

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"errors" => [%{"message" => "bad"}]}})
    assert {:error, {:linear_graphql_errors, [%{"message" => "bad"}]}} = Adapter.list_projects()

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :linear_projects_unexpected_payload} = Adapter.list_projects()

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})
    assert {:error, :boom} = Adapter.list_projects()

    System.put_env("LINEAR_API_KEY", "token")

    assert {:ok, single_entries} = Adapter.bootstrap_env_entries([alpha], assignee: "me")
    assert single_entries["LINEAR_API_KEY"] == "token"
    assert single_entries["LINEAR_PROJECT_SLUG"] == "alpha"
    assert single_entries["LINEAR_PROJECT_SLUGS"] == ""
    assert single_entries["LINEAR_ASSIGNEE"] == "me"

    System.put_env("LINEAR_API_KEY", "   ")
    assert {:ok, blank_entries} = Adapter.bootstrap_env_entries([alpha], assignee: "")
    refute Map.has_key?(blank_entries, "LINEAR_API_KEY")
    refute Map.has_key?(blank_entries, "LINEAR_ASSIGNEE")

    System.delete_env("LINEAR_API_KEY")
    assert {:ok, multi_entries} = Adapter.bootstrap_env_entries([alpha, beta], [])
    refute Map.has_key?(multi_entries, "LINEAR_API_KEY")
    assert multi_entries["LINEAR_PROJECT_SLUG"] == ""
    assert multi_entries["LINEAR_PROJECT_SLUGS"] == "alpha,beta"
  end

  test "linear adapter installs issue templates through provider implementation" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: "project-slug",
      tracker_project_slugs: ["project-slug"]
    )

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "projects" => %{
               "nodes" => [
                 %{
                   "id" => "project-1",
                   "name" => "Project",
                   "slugId" => "project-slug",
                   "teams" => %{"nodes" => [%{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}]}
                 }
               ]
             }
           }
         }},
        {:ok, %{"data" => %{"templates" => []}}},
        {:ok,
         %{
           "data" => %{
             "templateCreate" => %{
               "success" => true,
               "template" => %{"id" => "template-1", "type" => "issue", "name" => "Codex Agent Task"}
             }
           }
         }}
      ]
    )

    assert {:ok, [result]} = Adapter.install_issue_templates(update_existing: false)
    assert result.action == :created
    assert result.template.id == "template-1"
    assert result.context.team_key == "ENG"
    assert Enum.map(result.projects, & &1.slug) == ["project-slug"]
  end

  test "linear adapter installs dispatch labels through provider implementation" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: "project-slug",
      tracker_project_slugs: ["project-slug"]
    )

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "projects" => %{
               "nodes" => [
                 %{
                   "id" => "project-1",
                   "name" => "Project",
                   "slugId" => "project-slug",
                   "url" => "https://linear.app/acme/project/project-slug",
                   "teams" => %{"nodes" => [%{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}]}
                 }
               ]
             }
           }
         }},
        {:ok, %{"data" => %{"issueLabels" => %{"nodes" => []}}}},
        {:ok,
         %{
           "data" => %{
             "issueLabelCreate" => %{
               "success" => true,
               "issueLabel" => %{
                 "id" => "label-ready",
                 "name" => "agent-ready",
                 "description" => "Runner may spend credits on this issue.",
                 "color" => "#2ECC71",
                 "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
               }
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "issueLabelCreate" => %{
               "success" => true,
               "issueLabel" => %{
                 "id" => "label-paused",
                 "name" => "agent-paused",
                 "description" => "Runner must not start or continue this issue.",
                 "color" => "#E03131",
                 "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
               }
             }
           }
         }}
      ]
    )

    assert {:ok, results} = Adapter.install_labels(update_existing: false)
    assert Enum.map(results, & &1.action) == [:created, :created]
    assert Enum.map(results, & &1.label.name) == ["agent-ready", "agent-paused"]
    assert Enum.map(results, & &1.context.kind) == [:ready, :paused]
    assert Enum.map(results, &(&1.projects |> List.first() |> Map.fetch!(:slug))) == ["project-slug", "project-slug"]
  end

  test "linear adapter installs workflow states through provider implementation" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: "project-slug",
      tracker_project_slugs: ["project-slug"],
      tracker_bootstrap_states: ["Backlog", "Todo"]
    )

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "projects" => %{
               "nodes" => [
                 %{
                   "id" => "project-1",
                   "name" => "Project",
                   "slugId" => "project-slug",
                   "url" => "https://linear.app/acme/project/project-slug",
                   "teams" => %{
                     "nodes" => [
                       %{
                         "id" => "team-1",
                         "key" => "ENG",
                         "name" => "Engineering",
                         "states" => %{
                           "nodes" => [
                             %{
                               "id" => "state-backlog",
                               "name" => "Backlog",
                               "type" => "backlog",
                               "position" => 0,
                               "color" => "#bec2c8",
                               "description" => nil
                             }
                           ]
                         }
                       }
                     ]
                   }
                 }
               ]
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "workflowStateCreate" => %{
               "success" => true,
               "workflowState" => %{
                 "id" => "state-todo",
                 "name" => "Todo",
                 "type" => "unstarted",
                 "position" => 1,
                 "color" => "#E2E2E2",
                 "description" => "State used by the Symphony runner workflow.",
                 "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
               }
             }
           }
         }}
      ]
    )

    assert {:ok, results} = Adapter.install_workflow_states([])
    assert Enum.map(results, & &1.action) == [:unchanged, :created]
    assert Enum.map(results, & &1.state.name) == ["Backlog", "Todo"]
    assert Enum.map(results, &(&1.projects |> List.first() |> Map.fetch!(:slug))) == ["project-slug", "project-slug"]
  end

  test "linear adapter installs saved views through provider implementation" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: "project-slug",
      tracker_project_slugs: ["project-slug"]
    )

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "projects" => %{
               "nodes" => [
                 %{
                   "id" => "project-1",
                   "name" => "Project",
                   "slugId" => "project-slug",
                   "url" => "https://linear.app/acme/project/project-slug",
                   "teams" => %{
                     "nodes" => [
                       %{
                         "id" => "team-1",
                         "key" => "ENG",
                         "name" => "Engineering",
                         "states" => %{"nodes" => [%{"id" => "state-1", "name" => "Backlog", "type" => "backlog", "position" => 0}]}
                       }
                     ]
                   }
                 }
               ]
             }
           }
         }},
        {:ok, %{"data" => %{"customViews" => %{"nodes" => []}, "favorites" => %{"nodes" => []}}}},
        {:ok,
         %{
           "data" => %{
             "customViewCreate" => %{
               "success" => true,
               "customView" => %{
                 "id" => "view-all",
                 "name" => "Symphony: Project / All",
                 "description" => "All issues in Project visible to the Symphony runner.",
                 "filterData" => %{"project" => %{"id" => %{"eq" => "project-1"}}},
                 "shared" => true,
                 "slugId" => "view-all",
                 "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
               }
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "customViewCreate" => %{
               "success" => true,
               "customView" => %{
                 "id" => "view-ready",
                 "name" => "Symphony: Project / Ready",
                 "description" => "Issues in Project marked ready for the Symphony runner.",
                 "filterData" => %{
                   "project" => %{"id" => %{"eq" => "project-1"}},
                   "labels" => %{"some" => %{"name" => %{"eq" => "agent-ready"}}}
                 },
                 "shared" => true,
                 "slugId" => "view-ready",
                 "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
               }
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "customViewCreate" => %{
               "success" => true,
               "customView" => %{
                 "id" => "view-paused",
                 "name" => "Symphony: Project / Paused",
                 "description" => "Issues in Project paused for the Symphony runner.",
                 "filterData" => %{
                   "project" => %{"id" => %{"eq" => "project-1"}},
                   "labels" => %{"some" => %{"name" => %{"eq" => "agent-paused"}}}
                 },
                 "shared" => true,
                 "slugId" => "view-paused",
                 "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
               }
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "customViewCreate" => %{
               "success" => true,
               "customView" => %{
                 "id" => "view-backlog",
                 "name" => "Symphony: Project / Backlog",
                 "description" => "Issues in Project currently in Backlog.",
                 "filterData" => %{
                   "project" => %{"id" => %{"eq" => "project-1"}},
                   "state" => %{"name" => %{"eq" => "Backlog"}}
                 },
                 "shared" => true,
                 "slugId" => "view-backlog",
                 "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
               }
             }
           }
         }}
      ]
    )

    assert {:ok, results} = Adapter.install_views(skip_favorites: true)
    assert Enum.map(results, & &1.view.id) == ["view-all", "view-ready", "view-paused", "view-backlog"]
    assert Enum.all?(results, &(&1.context.favorite_action == :skipped))

    assert Enum.map(results, &(&1.projects |> List.first() |> Map.fetch!(:slug))) == [
             "project-slug",
             "project-slug",
             "project-slug",
             "project-slug"
           ]
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "activity" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "session_id" => "thread-http",
                 "event" => "notification",
                 "message" => "observed activity",
                 "at" => state_payload["activity"] |> List.first() |> Map.fetch!("at")
               }
             ],
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "project" => %{
                   "id" => "project-1",
                   "name" => "Entr'acte",
                   "slug" => "entracte",
                   "url" => "https://linear.app/acme/project/entracte"
                 },
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "workspace_git" => %{"available" => false, "reason" => "workspace unavailable"},
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "current_focus" => %{
                   "label" => "Active",
                   "detail" => "observed activity",
                   "kind" => "activity",
                   "at" => state_payload["running"] |> List.first() |> Map.fetch!("current_focus") |> Map.fetch!("at")
                 },
                 "milestones" => [],
                 "diagnostics" => %{
                   "events" => [
                     %{
                       "event" => "notification",
                       "message" => "observed activity",
                       "at" => state_payload["running"] |> List.first() |> get_in(["diagnostics", "events"]) |> List.first() |> Map.fetch!("at")
                     }
                   ],
                   "hidden_count" => 0
                 },
                 "recent_events" => [
                   %{
                     "event" => "notification",
                     "message" => "observed activity",
                     "at" => state_payload["running"] |> List.first() |> Map.fetch!("recent_events") |> List.first() |> Map.fetch!("at")
                   }
                 ],
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "codex_project_totals" => [
               %{
                 "project" => %{
                   "id" => "project-1",
                   "name" => "Entr'acte",
                   "slug" => "entracte",
                   "url" => "https://linear.app/acme/project/entracte"
                 },
                 "input_tokens" => 4,
                 "output_tokens" => 8,
                 "total_tokens" => 12,
                 "seconds_running" => 42.5
               }
             ],
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "workspace_git" => %{"available" => false, "reason" => "workspace unavailable"},
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "project" => %{
                 "id" => "project-1",
                 "name" => "Entr'acte",
                 "slug" => "entracte",
                 "url" => "https://linear.app/acme/project/entracte"
               },
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "current_focus" => %{
                 "label" => "Active",
                 "detail" => "observed activity",
                 "kind" => "activity",
                 "at" => issue_payload["running"]["current_focus"]["at"]
               },
               "milestones" => [],
               "diagnostics" => %{
                 "events" => [
                   %{
                     "event" => "notification",
                     "message" => "observed activity",
                     "at" => issue_payload["running"]["diagnostics"]["events"] |> List.first() |> Map.fetch!("at")
                   }
                 ],
                 "hidden_count" => 0
               },
               "recent_events" => [
                 %{
                   "event" => "notification",
                   "message" => "observed activity",
                   "at" => issue_payload["running"]["recent_events"] |> List.first() |> Map.fetch!("at")
                 }
               ],
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [
               %{
                 "event" => "notification",
                 "message" => "observed activity",
                 "at" => issue_payload["recent_events"] |> List.first() |> Map.fetch!("at")
               }
             ],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api summarizes noisy activity into readable focus" do
    orchestrator_name = Module.concat(__MODULE__, :HttpActivitySummaryOrchestrator)
    now = DateTime.utc_now()

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :codex_recent_events], [
        %{event: :notification, message: "item started: reasoning (rs_1)", timestamp: now},
        %{
          event: :notification,
          message: "command output streaming: github.com Logged in to github.com account",
          timestamp: DateTime.add(now, -1, :second)
        },
        %{
          event: :notification,
          message: "thread token usage updated (in 1, out 2, total 3)",
          timestamp: DateTime.add(now, -2, :second)
        }
      ])

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    running =
      build_conn()
      |> get("/api/v1/state")
      |> json_response(200)
      |> Map.fetch!("running")
      |> List.first()

    assert running["current_focus"]["label"] == "Checked GitHub auth"
    assert running["current_focus"]["kind"] == "git"
    assert [%{"label" => "Checked GitHub auth"}] = running["milestones"]
    assert running["diagnostics"]["hidden_count"] == 0
    assert length(running["diagnostics"]["events"]) == 3
  end

  test "phoenix observability api includes git workspace progress" do
    workspace = git_workspace!("dashboard-workspace-git")
    orchestrator_name = Module.concat(__MODULE__, :HttpWorkspaceGitOrchestrator)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :workspace_path], workspace)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    workspace_git =
      build_conn()
      |> get("/api/v1/state")
      |> json_response(200)
      |> Map.fetch!("running")
      |> List.first()
      |> Map.fetch!("workspace_git")

    assert workspace_git["available"] == true
    assert workspace_git["branch"] == "feature"
    assert workspace_git["head"]["subject"] == "feature work"
    assert workspace_git["base"]["short_sha"]
    assert workspace_git["relation"] == %{"ahead" => 1, "behind" => 0}
    assert workspace_git["working_tree"]["clean"] == true

    assert workspace_git["published"] == %{
             "branch" => "origin/feature",
             "has_remote_branch" => false,
             "head_pushed" => false,
             "published" => false
           }

    assert [%{"path" => "feature.txt", "status" => "A", "kind" => "added"}] = workspace_git["branch_diff"]["files"]
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    assert html =~ "Active issue focus, milestones, and diagnostics."
    assert html =~ "Console"
    assert html =~ "Recent event stream"
    assert html =~ "Show raw events"
    assert html =~ ~s(class="diagnostics-panel" phx-mounted)
    assert html =~ ~s(class="console-panel" phx-mounted)
    assert html =~ ~s(class="raw-activity-panel" phx-mounted)
    assert html =~ ~s(&quot;attrs&quot;:[&quot;open&quot;])
    assert length(String.split(html, "ignore_attrs")) == 4
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          project: %{
            id: "project-1",
            name: "Entr'acte",
            slug: "entracte",
            url: "https://linear.app/acme/project/entracte"
          },
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    activity_at = DateTime.utc_now()

    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          project: %{
            id: "project-1",
            name: "Entr'acte",
            slug: "entracte",
            url: "https://linear.app/acme/project/entracte"
          },
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_recent_events: [
            %{event: :notification, message: "observed activity", timestamp: activity_at}
          ],
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      codex_project_totals: [
        %{
          project: %{
            id: "project-1",
            name: "Entr'acte",
            slug: "entracte",
            url: "https://linear.app/acme/project/entracte"
          },
          input_tokens: 4,
          output_tokens: 8,
          total_tokens: 12,
          seconds_running: 42.5
        }
      ],
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp git_workspace!(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)

    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Test User"])
    File.write!(Path.join(path, "README.md"), "base\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "base"])
    git!(path, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(path, ["checkout", "-b", "feature"])
    File.write!(Path.join(path, "feature.txt"), "feature\n")
    git!(path, ["add", "feature.txt"])
    git!(path, ["commit", "-m", "feature work"])

    path
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
