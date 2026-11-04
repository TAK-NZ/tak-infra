# TAK-GPT model benchmark harness

Benchmarks Claude models on Amazon Bedrock for the TAK-GPT RELAY agent: speed and accuracy over a set of
emergency-management questions, judged blind by a stronger model. Results and conclusions are in
[docs/TAK_GPT_MODEL_BENCHMARK.md](../../../docs/TAK_GPT_MODEL_BENCHMARK.md).

The harness only reads and invokes: `bedrock-agent:GetAgentVersion`, `bedrock-agent-runtime:Retrieve`,
`bedrock-runtime:Converse`. It does not modify any agent, knowledge base or Lambda.

## Settings

No account or resource IDs are stored in the repository. Set them in the environment:

| Variable | Meaning |
|---|---|
| `BENCH_AWS_PROFILE` | AWS CLI profile of the account that owns the agent (optional) |
| `BENCH_REGION` | Region of the agent and knowledge base (default `ap-southeast-2`) |
| `BENCH_KB_ID` | Knowledge base ID the agent uses (required) |
| `BENCH_AGENT_ID`, `BENCH_AGENT_VERSION` | Agent and version to copy the instruction from. Alternatively put the instruction text in `results/agent_instruction.txt` |

## Run

```bash
export BENCH_AWS_PROFILE=... BENCH_KB_ID=... BENCH_AGENT_ID=... BENCH_AGENT_VERSION=...
cd scripts/bedrock/benchmark
python3 benchmark.py run --runs 3        # answers for every model x question x repeat (about 25 min)
python3 benchmark.py refs                # answer key per question from the judge model
python3 benchmark.py judge --workers 8   # blind scoring
python3 benchmark.py report              # tables in results/summary.json and results/summary_table.md
```

`questions.json` holds the sample questions. Candidate models are listed in `MODELS` in `benchmark.py`
(`sonnet-5.5-nothink` uses `thinking: {"type": "between_tools"}`, which is how Sonnet 5.5 turns thinking off).

`agent_compare.py` compares the old three-query travel rule with the `route_between` tool, calling the real Lambda code
locally (`COMPARE_REPS` sets the repeat count, `COMPARE_MODEL` the model).

## Not committed

`results/` raw output (`runs.jsonl`, `judgements.jsonl`, `references.json`, smoke runs, logs) is large, and
`results/rollback/` holds agent configuration backups with account-specific IDs. Both are in `.gitignore`.
