defmodule Anoma.Node.Transaction.Mempool do
  @moduledoc """

  """

  alias __MODULE__
  alias Anoma.Node
  alias Node.Registry
  alias Node.Transaction.{Storage, Executor, Backends}
  alias Backends.ResultEvent
  alias Executor.ExecutionEvent

  require Node.Event
  require Logger

  use GenServer
  use TypedStruct

  ############################################################
  #                         State                            #
  ############################################################

  @type vm_result :: {:ok, Noun.t()} | :error | :in_progress
  @type tx_result :: {:ok, any()} | :error | :in_progress
  @typep startup_options() :: {:node_id, String.t()}

  typedstruct module: Tx do
    field(:tx_result, Mempool.tx_result(), default: :in_progress)
    field(:vm_result, Mempool.vm_result(), default: :in_progress)
    field(:backend, Backends.backend())
    field(:code, Noun.t())
  end

  typedstruct module: TxEvent do
    field(:id, binary())
    field(:tx, Mempool.Tx.t())
  end

  typedstruct module: ConsensusEvent do
    field(:order, list(binary()))
  end

  typedstruct module: BlockEvent do
    field(:order, list(binary()))
    field(:round, non_neg_integer())
  end

  typedstruct do
    field(:node_id, String.t())

    field(
      :transactions,
      %{binary() => Mempool.Tx.t()},
      default: %{}
    )

    field(:round, non_neg_integer(), default: 0)
  end

  ############################################################
  #                    Genserver Helpers                     #
  ############################################################

  @spec start_link([startup_options()]) :: GenServer.on_start()
  def start_link(args \\ []) do
    name = Registry.via(args[:node_id], __MODULE__)
    GenServer.start_link(__MODULE__, args, name: name)
  end

  @spec init([startup_options()]) :: {:ok, Mempool.t()}
  def init(args) do
    Process.set_label(__MODULE__)

    args =
      args
      |> Keyword.validate!([
        :node_id,
        transactions: [],
        consensus: [],
        round: 0
      ])

    node_id = args[:node_id]

    EventBroker.subscribe_me([
      Node.Event.node_filter(node_id),
      filter_for_mempool()
    ])

    for {id, tx_w_backend} <- args[:transactions] do
      tx(args[:node_id], tx_w_backend, id)
    end

    consensus = args[:consensus]
    round = args[:round]

    for list <- consensus do
      execute(node_id, list)
    end

    {:ok, %__MODULE__{round: round, node_id: node_id}}
  end

  ############################################################
  #                      Public RPC API                      #
  ############################################################

  @spec tx_dump(String.t()) :: [Mempool.Tx.t()]
  def tx_dump(node_id) do
    GenServer.call(Registry.via(node_id, __MODULE__), :dump)
  end

  @spec tx(String.t(), {Backends.backend(), Noun.t()}) :: :ok
  def tx(node_id, tx_w_backend) do
    tx(node_id, tx_w_backend, :crypto.strong_rand_bytes(16))
  end

  # only to be called by Logging replays directly
  @spec tx(String.t(), {Backends.backend(), Noun.t()}, binary()) :: :ok
  def tx(node_id, tx_w_backend, id) do
    GenServer.cast(Registry.via(node_id, __MODULE__), {:tx, tx_w_backend, id})
  end

  # list of ids seen as ordered transactions
  @spec execute(String.t(), list(binary())) :: :ok
  def execute(node_id, ordered_list_of_txs) do
    GenServer.cast(
      Registry.via(node_id, __MODULE__),
      {:execute, ordered_list_of_txs}
    )
  end

  ############################################################
  #                      Public Filters                      #
  ############################################################

  @spec worker_module_filter() :: EventBroker.Filters.SourceModule.t()
  def worker_module_filter() do
    %EventBroker.Filters.SourceModule{module: Anoma.Node.Transaction.Backends}
  end

  @spec filter_for_mempool() :: Backends.ForMempoolFilter.t()
  def filter_for_mempool() do
    %Backends.ForMempoolFilter{}
  end

  ############################################################
  #                    Genserver Behavior                    #
  ############################################################

  def handle_call(:dump, _from, state) do
    {:reply, state.transactions |> Map.keys(), state}
  end

  def handle_call(_, _, state) do
    {:reply, :ok, state}
  end

  def handle_cast({:tx, tx, tx_id}, state) do
    {:noreply, handle_tx(tx, tx_id, state)}
  end

  def handle_cast({:execute, id_list}, state) do
    handle_execute(id_list, state)
    {:noreply, state}
  end

  def handle_cast(_, state) do
    {:noreply, state}
  end

  def handle_info(
        %EventBroker.Event{body: %Node.Event{body: %ResultEvent{}}} = e,
        state
      ) do
    {:noreply, handle_result_event(e, state)}
  end

  def handle_info(
        %EventBroker.Event{
          body: %Node.Event{body: %ExecutionEvent{}}
        } = e,
        state
      ) do
    {:noreply, handle_execution_event(e, state)}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  ############################################################
  #                 Genserver Implementation                 #
  ############################################################

  @spec handle_tx({Backends.backend(), Noun.t()}, binary(), t()) :: t()
  defp handle_tx({backend, code} = tx, tx_id, state = %Mempool{}) do
    value = %Tx{backend: backend, code: code}
    node_id = state.node_id

    tx_event(tx_id, value, node_id)

    Executor.launch(node_id, tx, tx_id)

    %Mempool{
      state
      | transactions: Map.put(state.transactions, tx_id, value)
    }
  end

  @spec handle_execute(list(binary()), t()) :: :ok
  defp handle_execute(id_list, state = %Mempool{}) do
    consensus_event(id_list, state.node_id)
    Executor.execute(state.node_id, id_list)
  end

  @spec handle_result_event(EventBroker.Event.t(), t()) :: t()
  defp handle_result_event(e, state = %Mempool{}) do
    id = e.body.body.tx_id
    res = e.body.body.vm_result

    new_map =
      state.transactions
      |> Map.update!(id, fn tx ->
        Map.put(tx, :vm_result, res)
      end)

    %Mempool{state | transactions: new_map}
  end

  @spec handle_execution_event(EventBroker.Event.t(), t()) :: t()
  defp handle_execution_event(e, state = %Mempool{}) do
    execution_list = e.body.body.result
    round = state.round
    node_id = state.node_id

    {writes, map} = process_execution(state, execution_list)

    Storage.commit(node_id, round, writes)

    block_event(Enum.map(execution_list, &elem(&1, 1)), round, node_id)

    %Mempool{state | transactions: map, round: round + 1}
  end

  ############################################################
  #                           Helpers                        #
  ############################################################

  @spec block_event(list(binary), non_neg_integer(), String.t()) :: :ok
  defp block_event(id_list, round, node_id) do
    block_event =
      Node.Event.new_with_body(node_id, %__MODULE__.BlockEvent{
        order: id_list,
        round: round
      })

    EventBroker.event(block_event)
  end

  @spec tx_event(binary(), Mempool.Tx.t(), String.t()) :: :ok
  defp tx_event(tx_id, value, node_id) do
    tx_event =
      Node.Event.new_with_body(node_id, %__MODULE__.TxEvent{
        id: tx_id,
        tx: value
      })

    EventBroker.event(tx_event)
  end

  @spec consensus_event(list(binary()), String.t()) :: :ok
  defp consensus_event(id_list, node_id) do
    consensus_event =
      Node.Event.new_with_body(node_id, %__MODULE__.ConsensusEvent{
        order: id_list
      })

    EventBroker.event(consensus_event)
  end

  @spec process_execution(t(), [{:ok | :error, binary()}]) ::
          {[Mempool.Tx.t()], %{binary() => Mempool.Tx.t()}}
  defp process_execution(state, execution_list) do
    for {tx_res, id} <- execution_list, reduce: {[], state.transactions} do
      {lst, ex_state} ->
        {tx_struct, map} =
          Map.get_and_update!(ex_state, id, fn _ -> :pop end)

        {[Map.put(tx_struct, :tx_result, tx_res) | lst], map}
    end
  end
end
