# TAK-GPT Model Benchmark (RELAY agent, ap-southeast-2)

Benchmark of Claude models available in Sydney for the TAK-GPT RELAY agent, run on 2026-11-03 against the Demo account, plus the rollout of the winner. For how the plugin is configured, see [TAK_GPT_PLUGIN.md](TAK_GPT_PLUGIN.md).

## Outcome

**Claude Sonnet 5.5 (`au.anthropic.claude-sonnet-5-5`) was both the most accurate and the fastest Sonnet.** Compared with the previous model, Sonnet 5, it answered 3.4 s faster on average (5.9 s vs 9.3 s) and scored 0.38 points higher on a 1-5 accuracy scale. It stays inside Australia, like the previous model.

| Environment | Agent | Before | After | Status |
|---|---|---|---|---|
| Demo (SYD) | RELAY (alias `live`) | v7, Sonnet 5 | **v9, Sonnet 5.5** | Switched and tested live |
| Demo (SYD) | SENTINEL (alias `live`) | v3, Sonnet 5 | **v4, Sonnet 5.5** | Switched and tested live. Not part of the benchmark (see Limitations) |
| Test (PDX) | RELAY (alias `live`) | v6, Sonnet 4.6 | **v7, Sonnet 5.5** (`us.anthropic.claude-sonnet-5-5`) | Switched and tested live. Also published the pending DRAFT changes (see Rollout notes). The benchmark ran in Sydney, not in the US region |
| Test (PDX) | SENTINEL | n/a | n/a | No SENTINEL agent exists in the Test account |

## Benchmark results

37 sample questions from the TAK.NZ RELAY test document, 3 repeats each, 6 models: 666 answers. Latency is the full agent turn (every model call plus every knowledge-base search), not time to first token.

| Model | Failed | Median s | Mean s | P90 s | Max s | Accuracy (1-5) | Correct | Complete | Grounded | Answers with an unsupported claim | Overconfident |
|---|---|---|---|---|---|---|---|---|---|---|---|
| haiku-4.5 | 0 | 4.5 | 5.3 | 9.2 | 16.6 | 3.54 | 3.63 | 3.59 | 3.41 | 44/111 | 21 |
| haiku-5.5 | 0 | 6.4 | 7.4 | 11.5 | 26.6 | 4.08 | 4.23 | 3.90 | 4.12 | 19/111 | 6 |
| sonnet-4.5 | 3 | 8.9 | 10.8 | 18.0 | 31.3 | 3.85 | 4.01 | 3.80 | 3.75 | 34/108 | 15 |
| sonnet-4.6 | 3 | 6.5 | 7.7 | 14.0 | 24.3 | 3.82 | 3.90 | 4.06 | 3.51 | 43/108 | 16 |
| sonnet-5 (previous) | 0 | 8.2 | 9.3 | 14.4 | 23.6 | 3.94 | 4.05 | 3.88 | 3.89 | 32/111 | 15 |
| **sonnet-5.5** | 0 | **5.2** | **5.9** | **8.7** | **12.5** | **4.32** | **4.52** | **4.17** | **4.27** | **14/111** | **2** |

- **Failed**: the model was still searching after 6 model calls and produced no answer. Only Sonnet 4.5 and 4.6 did this. Failed runs are excluded from the accuracy columns.
- **Accuracy** is the mean of correctness, completeness and groundedness (1-5 each), scored by Claude Opus 5.5 against an answer key built from the knowledge base. The judge did not see which model wrote an answer.
- **Answers with an unsupported claim** counts answers stating a specific code, number, name or citation that the knowledge base does not support. The judge is strict: a true but unsupported detail counts. Use it to compare models. It overstates real-world fabrication.
- **Overconfident**: the knowledge base did not answer the question but the model answered with specifics.
- Haiku 4.5 is about 0.6 s faster than Sonnet 5.5 on average, but it is clearly the least accurate, so it is not suitable here.

### Is the gap real?

Paired by question (37 questions), bootstrap 95% confidence interval. Positive accuracy and negative latency favour Sonnet 5.5.

| Sonnet 5.5 compared with | Accuracy difference | Latency difference |
|---|---|---|
| sonnet-5 (previous) | +0.38 [+0.24, +0.53] | -3.4 s [-4.2, -2.6] |
| haiku-5.5 | +0.24 [+0.12, +0.37] | -1.5 s [-2.1, -0.9] |
| sonnet-4.6 | +0.52 [+0.40, +0.63] | -1.8 s [-2.9, -0.8] |
| sonnet-4.5 | +0.48 [+0.32, +0.67] | -5.0 s [-6.3, -3.9] |
| haiku-4.5 | +0.78 [+0.59, +0.98] | +0.6 s [0.0, +1.2] |

Every accuracy interval excludes zero.

### By question category (accuracy 1-5 / median seconds)

| Model | Operational | Training & Safety | Org & Legal | Emergency Response | Geographic | Map Markers | Multi-Document |
|---|---|---|---|---|---|---|---|
| haiku-4.5 | 4.05 / 4.2 | 3.17 / 4.2 | 3.76 / 4.4 | 4.09 / 5.2 | 3.14 / 3.3 | 3.67 / 4.7 | 2.41 / 10.2 |
| haiku-5.5 | 4.22 / 7.1 | 3.90 / 5.5 | 4.04 / 6.0 | 4.53 / 6.9 | 4.19 / 5.9 | 4.03 / 7.7 | 3.52 / 13.3 |
| sonnet-4.5 | 4.32 / 8.4 | 3.44 / 8.6 | 4.15 / 9.1 | 4.40 / 8.8 | 4.00 / 7.4 | 3.47 / 9.6 | 2.74 / 22.5 |
| sonnet-4.6 | 4.00 / 5.6 | 3.72 / 5.6 | 3.93 / 6.6 | 4.36 / 6.5 | 3.67 / 4.0 | 3.75 / 7.1 | 2.85 / 20.6 |
| sonnet-5 | 4.29 / 7.1 | 3.85 / 8.2 | 4.19 / 8.9 | 4.40 / 7.9 | 3.72 / 6.4 | 3.69 / 9.9 | 2.74 / 19.6 |
| sonnet-5.5 | 4.41 / 5.3 | 4.31 / 5.0 | 4.41 / 5.5 | 4.67 / 4.8 | 4.03 / 4.9 | 4.61 / 5.4 | 3.41 / 10.6 |

Multi-document questions are the weak spot for every model (best 3.52). The knowledge base only partly covers them, so this reflects the content as much as the model.

## Which models are available in Sydney

Checked on 2026-11-03 with `list-inference-profiles` and `list-foundation-models` in `ap-southeast-2`. This is what the region lists, not a test that every model can be invoked from the Demo account.

- **Australia-resident (`au.*`) profiles:** 11, all Anthropic: Haiku 4.5, Haiku 5.5, Sonnet 4.5, 4.6, 5, 5.5, and Opus 4.6, 4.7, 4.8, 5, 5.5. The benchmark used the six Haiku and Sonnet ones. Opus was excluded by request.
- **Other Anthropic profiles:** `global.*` profiles for the same models plus Opus 4.5 and the Fable 5 / 5.1 models. `apac.*` has Claude 3 and 3.5 models, which are older.
- **Non-Anthropic:** the region lists models from Amazon, OpenAI, Mistral, Qwen, DeepSeek, Google, NVIDIA, Moonshot, MiniMax, Z.AI, Cohere, TwelveLabs and xAI. Of these, only the Amazon Nova models (`apac.*`) and various `global.*` profiles are reachable through a cross-region profile. A `global.*` profile may route outside Australia.

So no, the six tested are not the only models, but they are the Australia-resident Haiku and Sonnet options.

## Method

- **Agent path mimicked.** System prompt is the live agent's instruction (RELAY version 7) plus the orchestration guidelines. The knowledge base is a search tool returning 5 passages per search. Temperature 1.0, stop sequence `</answer>`, max tokens 2048.
- **Run order.** Each model's calls ran one at a time. The six models ran in parallel against separate endpoints, and repeats were interleaved to spread time-of-day drift. No throttling retries occurred.
- **Judging.** Claude Opus 5.5 first built an answer key per question from the knowledge base, then scored each answer blind against it.
- **Code and data.** The harness is in `scripts/bedrock/benchmark/` (see its README). The summary numbers are committed (`results/summary.json`, `results/agent_compare.json`). The raw answers, judge rationales and answer keys are about 16 MB and were not committed; rerun the harness to regenerate them. Rerun with the settings described in that README:

```bash
cd scripts/bedrock/benchmark
python3 benchmark.py run --runs 3       # about 25 min
python3 benchmark.py refs
python3 benchmark.py judge --workers 8  # about 12 min
python3 benchmark.py report
```

Requires an AWS profile (set `BENCH_AWS_PROFILE`) with `bedrock:Converse` and `bedrock:Retrieve`.

## Limitations

- **Action-group tools were not included.** The live agents also have `geocode`, `live-data` and `tak-tools`. The sample questions are knowledge-base questions, so tool-heavy flows (placing markers, drive times, live conditions) are untested on Sonnet 5.5.
- **Not run through the Bedrock Agents runtime.** The benchmark used the Converse API with a search tool. Absolute latencies in production will be higher. After the rollout, live agent answers took about 5-6 s for single questions, which is consistent with the benchmark.
- **Judge is a model.** There are no human reference answers. Spot checks of flagged answers found real errors (shifted phone numbers, invented station numbers), but a human review of safety-critical answers is still worthwhile.
- **SENTINEL was not benchmarked.** The test document has no SENTINEL questions. It was switched on the strength of the RELAY results and verified with two live questions (K2 and NZDDP-D doctrine).
- **Iteration cap of 6** in the harness, so the six failures (Sonnet 4.5 and 4.6) are indicative only.

## Rollout notes

### Sonnet 5.5 needs a pinned orchestration prompt

Changing only the model on an agent with default prompts **breaks the agent**. When Bedrock regenerates the default orchestration settings for Sonnet 5.5, it adds `additionalModelRequestFields: {thinking: {type: enabled, budget_tokens: 1024}}`. Sonnet 5.5 rejects that format:

```
"thinking.type.enabled" is not supported for this model. Use "thinking.type.adaptive" and "output_config.effort" ...
```

This happened on Demo RELAY: for about three minutes (06:37 to roughly 06:40 UTC on 2026-11-03) the agent's DRAFT, and alias version 8, were on the broken configuration. The TAK plugin calls the draft alias (`TSTALIASID`), so the DRAFT is what chat used, and moving the live alias back to version 7 did not by itself restore service; fixing DRAFT did. The Demo logs show no chat messages in that window, so no user was affected. Versions 9 (RELAY) and 4 (SENTINEL) fix it by setting the ORCHESTRATION prompt to `OVERRIDDEN` with the same template, temperature (1.0) and stop sequence (`</answer>`) as before, and no `thinking` field. The other four prompt types stay `DEFAULT` and disabled.

### `setup-bedrock-agent.py` now sets the model and the pinned prompt

`scripts/bedrock/setup-bedrock-agent.py` was updated so that re-running it keeps this configuration:

- The model is set in one place (`AGENT_MODEL_NAME`, currently `claude-sonnet-5-5`). `default_model_id()` builds `au.anthropic.<name>` for AU/NZ regions and `us.anthropic.<name>` for US regions.
- Both `create_agent` and `update_agent` now pass the pinned orchestration prompt (`prompt_override_config()`), which reads the template from `scripts/bedrock/orchestration-prompt-template.txt`. That file is the exact template the agents ran before, so only the thinking field is gone.
- Verified by applying the script's prompt config to the Demo SENTINEL DRAFT: the result matched live version 4 exactly.
- The full script was not re-run, so the other steps (IAM role, knowledge base, Lambdas) are unchanged and untested by this change.

Trade-off: with a pinned template, improvements Bedrock makes to its default orchestration template for future models are not picked up automatically. Compare against a fresh default when changing model family.

### Test (PDX) RELAY: switched together with its pending DRAFT

Test RELAY's live version (v6, created 2026-03-04) was older than its DRAFT (2026-03-08), so publishing the model change also published the DRAFT changes, as agreed:

- a rewritten instruction (marker placement rules, NZEM iconset section, "kea" wording, 5-bullet limit),
- the `geocode` and `tak-tools` action groups (v6 had only `live-data`),
- the model change and pinned prompt described above. The previous live prompt had Bedrock's `thinking` setting enabled with a 1024-token budget on Sonnet 4.6. That setting is no longer sent (see below).

Checked on the DRAFT before publishing (K2 question, PAN PAN question, a live drive-time question using the `live-data` tool, and an Invercargill coordinates question), then on the live alias (K2 and VHF channel questions). The `geocode` and `tak-tools` action groups were **not** exercised: `tak-tools` returns control to the plugin, so it can only be tested end to end from a TAK client. The Test knowledge base has no maritime documents, so maritime answers there come from general knowledge and say so.

## About "thinking"

Thinking here means Claude's extended reasoning: the model writes hidden reasoning tokens before answering. That costs time and output tokens, which matches the experience on the other project. It was **not** the cause of the outage, but it is related.

**What broke.** Bedrock Agents add a thinking setting to the default prompt of newer Claude models: `thinking: {type: enabled, budget_tokens: 1024}`, the older "fixed budget" form. Sonnet 5.5 only accepts the newer adaptive form, where the model decides per request whether to think. So the request was rejected. That was a format incompatibility, not a performance problem. Test RELAY's v6 had the old setting on Sonnet 4.6; Demo's Sonnet 5 versions did not.

**What the pinned prompt does now.** It sends no thinking field at all. The benchmark ran the same way, so the results above apply. With no field sent, each model uses its own default:

| Model | Runs that produced reasoning | Avg output tokens per answer |
|---|---|---|
| sonnet-4.5 | 0/111 | 404 |
| sonnet-4.6 | 0/111 | 519 |
| haiku-4.5 | 0/111 | 428 |
| sonnet-5 (previous) | 80/111 | 556 |
| sonnet-5.5 | 28/111 | 588 |
| haiku-5.5 | 111/111 | 1000 |

- Sonnet 5.5 reasoned on about a quarter of answers, much less than Sonnet 5 (72%), and its output tokens are close to Sonnet 5's. Its mean latency was still 3.4 s lower.
- Sonnet 5.5 answers that included reasoning averaged 7.7 s against 5.3 s without. That gap is partly because harder questions trigger reasoning, so it overstates the cost of thinking itself.
- Haiku 5.5 reasoned on every answer, which is why it uses about twice the tokens and is slower than Sonnet 5.5.

**Turning it off: tested, and not worth it.** Sonnet 5.5 does not accept `thinking: {type: disabled}`. It requires `thinking: {type: between_tools}` to switch reasoning off (no reasoning before answering, only short updates between tool calls). I reran the benchmark (37 questions × 3 repeats) with that setting, side by side with a fresh control run at the default settings, so time-of-day drift affects both equally.

| Sonnet 5.5 variant | Median s | Mean s | P90 s | Max s | Accuracy (1-5) | Unsupported-claim answers | Avg searches | Avg output tokens | Runs that reasoned |
|---|---|---|---|---|---|---|---|---|---|
| default (control) | 5.2 | 6.1 | 9.7 | 14.0 | 4.29 | 20/111 | 2.4 | 578 | 26/111 |
| thinking off (`between_tools`) | 6.6 | 7.5 | 10.9 | 21.4 | 4.33 | 25/111 | 3.1 | 702 | 0/111 |

Paired by question, thinking off minus default: accuracy +0.05 [-0.06, +0.16] (no detectable difference), latency **+1.36 s** [+0.86, +1.88], output tokens **+124** [+93, +157]. The control matched the original Sonnet 5.5 run within noise (accuracy -0.04, latency +0.17 s), so the result is reproducible.

Turning thinking off made Sonnet 5.5 **slower and more verbose**. Without a short reasoning step first, it ran more searches (3.1 vs 2.4 per answer) and wrote longer answers. The slowest answer went from 14.0 s to 21.4 s, and multi-document questions from 10.3 s to 15.2 s (median). The default (no thinking field sent) is the better setting for this agent. This is a different outcome from the project where thinking was slow and wasteful: there the reasoning budget was probably large and fixed, whereas Sonnet 5.5's default reasoning is short and adaptive (26 of 111 runs).

## Incident: "Unable to execute HTTP request: null" (Demo, 2026-11-03)

**What happened.** A user asked RELAY "The far is Te Anau from Queenstown" and got `Error while talking to bot: ...SdkClientException: Unable to execute HTTP request: null`.

**Root cause: a 30-second HTTP read timeout in the plugin.**

- The TAK server log shows the message reaching the plugin at 02:27:10.672 UTC and the exception at 02:27:40.720 UTC, which is 30.05 seconds later. The root cause in the stack trace is `io.netty.handler.timeout.ReadTimeoutException`.
- `BedrockChatManager` builds its `BedrockAgentRuntimeAsyncClient` with default HTTP settings, and the Netty client's default read timeout is 30 seconds. `InvokeAgent` sends nothing back until the agent has finished all its steps, so any agent turn longer than 30 s is cut off by the HTTP client. The plugin's own 60 s limit (`TIMEOUT_AGENT_S`) never gets a chance to apply, and the "Bot unavailable" message for that limit never appears (zero occurrences in the logs).
- The SDK wraps this as "Unable to execute HTTP request" and, because the timeout exception has no message, the text ends in `null`.

**Why that request was slow.** It was a travel-time question. The agent instruction requires a place lookup for each town and three route-delay queries, and the agent ran extra rounds. In the Lambda logs for that minute, the geocode Lambda cold-started (3.5 s), three GeoJSON Lambda instances cold-started at once at 02:27:23, and the agent made another place lookup at 02:27:35. The last model step, which writes the answer (about 1,000 tokens, roughly 8 s in the replays), could not have finished before 02:27:40. Replaying the same question on the live agent afterwards took 15.0 to 20.8 s warm, so this is a slow run, not a hard fault, but the margin to 30 s is small.

**Unrelated to the model change.** At that time the live version was v7 (Sonnet 5). Version 8 was created at 06:37 UTC, four hours later.

**Is it sporadic?** It will recur whenever a turn passes 30 s, most likely on travel-time or multi-tool questions and on Lambda cold starts. Over the 30 days of retained logs there is exactly one such exception. Usage is low (23 chat messages reached the LLM in the last 14 days), so the rate cannot be estimated reliably.

**Fixes.**

1. **Routing tool (deployed 2026-11-03).** `route_between` in the ArcGIS Lambda replaced the multi-call travel rule. The average travel turn went from 16.7 s to 4.4 s in testing, and about 4-8 s through the live agents (see [TAK_GPT_PLUGIN.md](TAK_GPT_PLUGIN.md#driving-routes-route_between)). This removes the usual cause of turns reaching 30 s.
2. **Plugin timeout (in the repo, not yet deployed).** `BedrockChatManager.java` now sets the agent client's Netty read timeout to 70 s (`TIMEOUT_AGENT_S` + 10), so the plugin's own 60 s limit applies instead of the SDK's 30 s default. Timeouts and connection failures return the standard "Bot unavailable, try again shortly" text, and other failures show the root cause instead of Java wrapper names. It needs a TAK server image rebuild and deploy through your CI. `docker/tak-server/plugin-build.gradle` gains an explicit `netty-nio-client` 2.29.45 dependency. Verified in isolation with a JDK 17 harness: the default client failed after 30.2 s against a server that never answers (the incident), the configured one waited its full setting, and the error mapping passed 7 checks including the exact incident shape. The full plugin could not be built locally because it needs the TAK server libraries, so the CI build is the final check.
3. Do not turn thinking off (see the comparison above).

### Rollback

**Important: the TAK plugin invokes the agents through `agentAliasId: TSTALIASID`, which is the DRAFT, not the `live` alias** (see `takserver-plugins/tak-gpt/tak.server.plugins.TAKChatBotBase.yaml` in each environment's config bucket). Any change to an agent's DRAFT therefore reaches chat as soon as the agent is prepared. Moving the `live` alias only matters for clients that call `live`.

Rolling back means restoring the DRAFT as well as the alias. Agent versions are immutable, so the old configuration can be re-applied from a backup of the agent's DRAFT, action groups and alias state. Take such a backup (`get-agent`, `get-agent-action-group`, `get-agent-alias`) before changing an agent; the backups made during this work contain account-specific IDs and were kept out of the repository. To make chat use a published version instead, set `agentAliasId` in the plugin config to the `live` alias ID.

```bash
# Demo RELAY back to Sonnet 5 (version 7)
aws bedrock-agent update-agent-alias --profile <DEMO_PROFILE> --region ap-southeast-2 \
  --agent-id <RELAY_AGENT_ID> --agent-alias-id <LIVE_ALIAS_ID> --agent-alias-name live \
  --routing-configuration agentVersion=7

# Demo SENTINEL back to Sonnet 5 (version 3)
aws bedrock-agent update-agent-alias --profile <DEMO_PROFILE> --region ap-southeast-2 \
  --agent-id <SENTINEL_AGENT_ID> --agent-alias-id <LIVE_ALIAS_ID> --agent-alias-name live \
  --routing-configuration agentVersion=3

# Test RELAY back to Sonnet 4.6 and the previous instruction (version 6)
aws bedrock-agent update-agent-alias --region us-west-2 \
  --agent-id <RELAY_AGENT_ID> --agent-alias-id <LIVE_ALIAS_ID> --agent-alias-name live \
  --routing-configuration agentVersion=6
```

These commands only move the `live` alias. Because the plugin uses the DRAFT (see above), also restore the DRAFT from the matching backup file to roll back chat. The agents' DRAFT is currently on Sonnet 5.5.
