defmodule Hyperledger.LogEntryModelTest do
  use Hyperledger.ModelCase
  
  import Mock
  import Hyperledger.TestFactory
  
  alias Hyperledger.SecretStore
  
  alias Hyperledger.LogEntry
  alias Hyperledger.Ledger
  alias Hyperledger.Account
  alias Hyperledger.Issue
  alias Hyperledger.Transfer
  alias Hyperledger.PrepareConfirmation
  alias Hyperledger.CommitConfirmation
    
  defp changeset_for_ledger do
    {:ok, secret_store} = SecretStore.start_link
    changeset_for_ledger("123", secret_store)
  end
  
  defp changeset_for_ledger(contract, secret_store) do
    params = ledger_params(contract, secret_store)
    public_key = params.ledger[:publicKey]
    gen_changeset("ledger/create", params, public_key, secret_store)
  end
  
  defp changeset_for_account(ledger_hash, secret_store) do
    params = account_params(ledger_hash, secret_store)
    public_key = params.account[:publicKey]
    gen_changeset("account/create", params, public_key, secret_store)
  end
  
  defp changeset_for_issue(ledger, secret_store) do
    params = issue_params(ledger.hash)
    gen_changeset("issue/create", params, ledger.public_key, secret_store)
  end
  
  defp changeset_for_transfer(source_key, dest_key, secret_store) do
    params = transfer_params(source_key, dest_key)
    gen_changeset("transfer/create", params, source_key, secret_store)
  end
  
  defp gen_changeset(command, params, public_key, secret_store) do
    params = log_entry_params(command, params, public_key, secret_store)
    LogEntry.changeset(%LogEntry{}, params[:logEntry])
  end
  
  defp sample_ledger_data do
    Poison.encode!(ledger_params)
  end
  
  setup do
    create_primary
    {:ok, secret_store} = SecretStore.start_link
    {:ok, secret_store: secret_store}
  end
  
  test "`changeset` validates signature" do
    {:ok, alt_store} = SecretStore.start_link
    {pk, _} = key_pair
    {_, sk} = key_pair
    pk = Base.encode16(pk)
    SecretStore.put(alt_store, pk, sk)
    cs = gen_changeset("ledger/create", ledger_params, pk, alt_store)

    assert cs.valid? == false
    
    cs = changeset_for_ledger
    
    assert cs.valid? == true
  end
  
  test "creating the first log entry sets the id and view to 1" do
    {:ok, log_entry} = LogEntry.create(changeset_for_ledger)
    
    assert log_entry.id   == 1
    assert log_entry.view == 1
  end
  
  test "creating a log entry also appends a prepare confirmation from self" do
    {:ok, log_entry} = LogEntry.create(changeset_for_ledger)
        
    assert Repo.all(assoc(log_entry, :prepare_confirmations)) |> Enum.count == 1
  end
  
  test "creating a log entry broadcasts a prepare to other nodes" do
    node = create_node(2)
    cs = changeset_for_ledger
    data = cs.changes.data
    headers = ["Content-Type": "application/json"]

    body =
      %{
        logEntry: %{
          id: 1,
          view: 1,
          command: "ledger/create",
          data: data
        },
        prepareConfirmations: [%{nodeId: 1, signature: "temp_signature"}],
        commitConfirmations: []}
        |> Poison.encode!
    
    with_mock HTTPotion,
    post: fn(_, _) -> %HTTPotion.Response{status_code: 201} end do
      LogEntry.create(cs)
      
      assert(
        called(
          HTTPotion.post(
            "#{node.url}/log",
            headers: headers,
            body: body
          )
        )
      )
    end
  end
  
  test "inserting a log entry broadcasts a prepare to other nodes" do
    inital_node_url = System.get_env("NODE_URL")
    node = create_node(2)
    System.put_env("NODE_URL", node.url)
    create_node(3)
    
    data = changeset_for_ledger.changes.data
    headers = ["Content-Type": "application/json"]
    body = %{logEntry: %{id: 1, view: 1, command: "ledger/create",
                         data: data},
             prepareConfirmations: [
               %{nodeId: 1, signature: "temp_signature"},
               %{nodeId: 2, signature: "temp_signature"}],
             commitConfirmations: []}
           |> Poison.encode!
           
    with_mock HTTPotion,
    post: fn(_, _) -> %HTTPotion.Response{status_code: 201} end do
      LogEntry.insert id: 1, view: 1, command: "ledger/create", data: data,
        prepare_confirmations: [%{node_id: 1, signature: "temp_signature"}],
        commit_confirmations: []
      
      assert(
        called(
          HTTPotion.post(
            "#{inital_node_url}/log",
            headers: headers,
            body: body
          )
        )
      )
    end
  end
  
  test "a log entry marked as prepared broadcasts a commit to other nodes" do
    node = create_node(2)
    cs = changeset_for_ledger
    headers = ["Content-Type": "application/json"]
    body =
      %{
        logEntry: %{
          id: 1,
          view: 1,
          command: "ledger/create",
          data: cs.changes.data
        },
        prepareConfirmations: [
          %{nodeId: 1, signature: "temp_signature"},
          %{nodeId: 2, signature: "temp_signature"}
        ],
        commitConfirmations: [
          %{nodeId: 1, signature: "temp_signature"}
        ]
      }
      |> Poison.encode!
         
    with_mock HTTPotion,
    post: fn(_, _) -> %HTTPotion.Response{status_code: 201} end do
      LogEntry.create(cs)
      
      LogEntry.insert id: 1, view: 1, command: "ledger/create", data: cs.changes.data,
        prepare_confirmations: [%{node_id: 2, signature: "temp_signature"}],
        commit_confirmations: []
        
      assert(
        called(
          HTTPotion.post(
            "#{node.url}/log",
            headers: headers,
            body: body
          )
        )
      )
    end
  end
  
  test "commit confirmations are appended to the record and become marked as committed" do
    create_node(2)
    LogEntry.create(changeset_for_ledger)
    LogEntry.insert id: 1, view: 1, command: "ledger/create",
      data: sample_ledger_data, prepare_confirmations: [
        %{node_id: 2, signature: "temp_signature"}], commit_confirmations: []
    
    LogEntry.insert id: 1, view: 1, command: "ledger/create",
      data: sample_ledger_data, prepare_confirmations: [],
      commit_confirmations: [%{node_id: 2, signature: "temp_signature"}]

    assert Repo.all(CommitConfirmation) |> Enum.count == 2
    assert Repo.get(LogEntry, 1).committed
  end
  
  test "inserting a log entry returns error if primary has no existing record" do
    assert {:error, _} = LogEntry.insert id: 1, view: 1, command: "ledger/create",
      data: sample_ledger_data, prepare_confirmations: [], commit_confirmations: []
  end
  
  test "inserting a log entry returns ok if primary has record which matches" do
    LogEntry.create(changeset_for_ledger)
    assert {:ok, %LogEntry{}} = LogEntry.insert(
      id: 1, view: 1, command: "ledger/create", data: sample_ledger_data,
      prepare_confirmations: [%{node_id: 1, signature: "temp_signature"},
                              %{node_id: 2, signature: "temp_signature"}],
      commit_confirmations: [])
    assert Repo.all(PrepareConfirmation) |> Enum.count == 2
    assert Repo.get(LogEntry, 1).prepared == true
  end
    
  test "inserting a log entry returns ok if node is not primary" do
    node = create_node(2)
    System.put_env("NODE_URL", node.url)

    assert {:ok, %LogEntry{}} = LogEntry.insert(
      id: 1, view: 1, command: "ledger/create", data: sample_ledger_data,
      prepare_confirmations: [%{node_id: 1, signature: "temp_signature"}],
      commit_confirmations: [])
  end
  
  test "inserting a log entry saves the confirmations and appends its own" do
    node = create_node(2)
    System.put_env("NODE_URL", node.url)

    LogEntry.insert id: 1, view: 1, command: "ledger/create",
      data: sample_ledger_data, prepare_confirmations: [%{
        node_id: 1, signature: "temp_signature"}], commit_confirmations: []
    
    assert Repo.all(PrepareConfirmation) |> Enum.count == 2
    
    LogEntry.insert id: 1, view: 1, command: "ledger/create", data: sample_ledger_data,
      prepare_confirmations: [%{node_id: 1, signature: "temp_signature"}],
      commit_confirmations: [%{node_id: 1, signature: "temp_signature"}]
    
    assert Repo.all(CommitConfirmation) |> Enum.count == 2
  end
  
  test "when a log entry passes the quorum for prepare confirmations it is marked as prepared" do
    node = create_node(2)
    {:ok, log_entry} = LogEntry.create(changeset_for_ledger)
    
    assert log_entry.prepared == false
    
    LogEntry.add_prepare(log_entry, node.id, "temp_signature")
    
    assert Repo.get(LogEntry, log_entry.id).prepared == true
  end
  
  test "when a log entry is marked as prepared the node adds a commit confirmation" do
    node = create_node(2)
    {:ok, log_entry} = LogEntry.create(changeset_for_ledger)

    assert Repo.all(assoc(log_entry, :commit_confirmations)) == []
    
    LogEntry.add_prepare(log_entry, node.id, "temp_signature")
    
    assert Repo.all(assoc(log_entry, :commit_confirmations)) |> Enum.count == 1
  end
  
  test "when a log entry passes the quorum for commit confirmations it is marked as committed and executed" do
    node = create_node(2)
    {:ok, log_entry} = LogEntry.create(changeset_for_ledger)
    LogEntry.add_prepare(log_entry, node.id, "temp_signature")
    
    log_entry = Repo.get(LogEntry, log_entry.id)
    assert log_entry.committed == false

    LogEntry.add_commit(log_entry, node.id, "temp_signature")
    
    log_entry = Repo.get(LogEntry, log_entry.id)
    assert log_entry.prepared  == true
    assert log_entry.committed == true
    assert log_entry.executed  == true
  end
  
  test "log entries are executed in order", %{secret_store: secret_store} do
    node = create_node(2)
    {:ok, log_entry_1} = LogEntry.create(changeset_for_ledger("123", secret_store))
    {:ok, log_entry_2} = LogEntry.create(changeset_for_ledger("456", secret_store))
    LogEntry.add_prepare(log_entry_1, node.id, "temp_signature")
    LogEntry.add_prepare(log_entry_2, node.id, "temp_signature")
    LogEntry.add_commit(log_entry_2, node.id, "temp_signature")
    
    assert Repo.all(Ledger) |> Enum.count == 0

    LogEntry.add_commit(log_entry_1, node.id, "temp_signature")
    
    assert Repo.all(Ledger) |> Enum.count == 2
  end
  
  test "executing log entry creates ledger with a primary account" do
    LogEntry.create(changeset_for_ledger)
        
    assert Repo.all(Ledger)   |> Enum.count == 1
    assert Repo.all(Account)  |> Enum.count == 1
  end
  
  test "executing log entry creates account", %{secret_store: secret_store} do
    {:ok, ledger} = create_ledger
    LogEntry.create(changeset_for_account(ledger.hash, secret_store))
    
    assert Repo.all(LogEntry) |> Enum.count == 1
    assert Repo.all(Account)  |> Enum.count == 2
  end
  
  test "executing log entry creates issue and changes primary wallet balances", %{secret_store: secret_store} do
    {:ok, ledger} = create_ledger("123", secret_store)
    LogEntry.create(changeset_for_issue(ledger, secret_store))
        
    assert Repo.all(Issue)    |> Enum.count == 1
    assert Repo.get(Account, ledger.primary_account_public_key).balance == 100
  end
  
  test "executing log entry creates transfer and changes wallet balances", %{secret_store: secret_store} do
    {:ok, ledger} = create_ledger("123", secret_store)
    LogEntry.create(changeset_for_issue(ledger, secret_store))
    dest_params = account_params(ledger.hash, secret_store)
    dest_key = dest_params.account[:publicKey]
    LogEntry.create(
      gen_changeset(
        "account/create",
        dest_params,
        dest_key,
        secret_store
      )
    )
        
    LogEntry.create(
      changeset_for_transfer(
        ledger.primary_account_public_key,
        dest_key, secret_store
      )
    )
    
    assert Repo.all(Transfer) |> Enum.count == 1
    assert Repo.get(Account, ledger.primary_account_public_key).balance == 0
    assert Repo.get(Account, dest_key).balance == 100
  end
end