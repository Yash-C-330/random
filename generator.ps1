$ErrorActionPreference = 'Stop'

function New-Node {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Type,
        [double]$TypeVersion,
        [array]$Position,
        $Parameters,
        $Credentials = $null
    )

    $node = [ordered]@{
        id = $Id
        name = $Name
        type = $Type
        typeVersion = $TypeVersion
        position = $Position
        parameters = $Parameters
    }

    if ($null -ne $Credentials) {
        $node.credentials = $Credentials
    }

    return $node
}

function New-Workflow {
    param(
        [string]$Id,
        [string]$Name,
        [array]$Nodes,
        [hashtable]$Connections
    )

    return [ordered]@{
        id = $Id
        name = $Name
        active = $false
        settings = [ordered]@{ executionOrder = 'v1' }
        versionId = "v-$Id"
        pinData = [ordered]@{}
        tags = @()
        nodes = $Nodes
        connections = $Connections
    }
}

function New-AgentWorkflow {
    param(
        [string]$Id,
        [string]$Name,
        [string]$AgentName,
        [string]$SystemPrompt,
        [string]$OutputKey,
        [bool]$UseToggle = $false,
        [string]$ToggleEnv = ''
    )

    $claimQuery = "UPDATE public.agent_messages SET state='claimed', attempts=attempts+1, updated_at=now() WHERE id=(SELECT id FROM public.agent_messages WHERE to_agent='$AgentName' AND state='queued' ORDER BY priority DESC, created_at ASC FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING *;"
    $doneQuery = "UPDATE public.agent_messages SET state='done', updated_at=now() WHERE id={{$json.id}};"
    $failQuery = "UPDATE public.agent_messages SET state=CASE WHEN attempts>=3 THEN 'failed' ELSE 'queued' END, error='json_validation_failed', updated_at=now() WHERE id={{$json.id}};"
    $answerQuery = "INSERT INTO public.agent_messages(thread_id, task_id, from_agent, to_agent, kind, state, priority, payload) VALUES ({{$json.thread_id}}, {{$json.task_id}}, '$AgentName', 'coordinator', 'answer', 'queued', 1, {{$json.parsed}});"
    $blackboardQuery = "INSERT INTO public.blackboard(task_id, key, value, producer_agent) VALUES ({{$json.task_id}}, '$OutputKey', {{$json.parsed}}, '$AgentName') ON CONFLICT (task_id, key) DO UPDATE SET value=EXCLUDED.value, producer_agent=EXCLUDED.producer_agent, updated_at=now();"
    $analysisQuery = "INSERT INTO public.social_analysis(task_id, agent, raw_llm_response, topics, creative_type, hook_style, target_audience, emotional_tone, compliance_flags, cta_type, claims_summary, quality_score, reasons, top_quote, hashtags, entities, suggested_counter_angles, brand_safety_risks, language, detected_format) VALUES ({{$json.task_id}}, '$AgentName', {{$json.parsed}}, {{$json.parsed.topics || []}}, {{$json.parsed.creative_type || null}}, {{$json.parsed.hook_style || null}}, {{$json.parsed.target_audience || null}}, {{$json.parsed.emotional_tone || null}}, {{$json.parsed.compliance_flags || []}}, {{$json.parsed.cta_type || null}}, {{$json.parsed.claims_summary || null}}, {{$json.parsed.quality_score || null}}, {{$json.parsed.reasons || null}}, {{$json.parsed.top_quote || null}}, {{$json.parsed.hashtags || []}}, {{$json.parsed.entities || {}}}, {{$json.parsed.suggested_counter_angles || []}}, {{$json.parsed.brand_safety_risks || []}}, {{$json.parsed.language || null}}, {{$json.parsed.detected_format || null}});"
    $logNoMessageQuery = "INSERT INTO public.logs(level, agent, message, meta) VALUES ('debug', '$AgentName', 'no queued message', '{""state"":""idle""}'::jsonb);"

    $nodes = @(
        (New-Node -Id 'cron' -Name 'Cron Poll' -Type 'n8n-nodes-base.cron' -TypeVersion 1 -Position @(120,220) -Parameters ([ordered]@{
            triggerTimes = [ordered]@{
                item = @([ordered]@{ mode = 'everyMinute' })
            }
        })),
        (New-Node -Id 'webhook' -Name 'Webhook Trigger' -Type 'n8n-nodes-base.webhook' -TypeVersion 2 -Position @(120,380) -Parameters ([ordered]@{
            path = "agents/$AgentName/trigger"
            httpMethod = 'POST'
            responseMode = 'onReceived'
            responseData = 'allEntries'
        })),
        (New-Node -Id 'merge' -Name 'Merge Trigger' -Type 'n8n-nodes-base.merge' -TypeVersion 3 -Position @(320,300) -Parameters ([ordered]@{ mode = 'append' })),
        (New-Node -Id 'set' -Name 'Set Config' -Type 'n8n-nodes-base.set' -TypeVersion 3.4 -Position @(520,300) -Parameters ([ordered]@{
            assignments = [ordered]@{
                assignments = @(
                    [ordered]@{ id='1'; name='agent_name'; type='string'; value=$AgentName },
                    [ordered]@{ id='2'; name='system_prompt'; type='string'; value=$SystemPrompt }
                )
            }
            options = [ordered]@{}
        }))
    )

    if ($UseToggle) {
        $nodes += (New-Node -Id 'toggle' -Name 'Feature Enabled?' -Type 'n8n-nodes-base.if' -TypeVersion 2 -Position @(720,300) -Parameters ([ordered]@{
            conditions = [ordered]@{
                string = @([ordered]@{ value1 = "={{ `$env.$ToggleEnv }}"; operation = 'equal'; value2 = 'true' })
            }
        }))
    }

    $nodes += @(
        (New-Node -Id 'claim' -Name 'Claim Message' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(920,300) -Parameters ([ordered]@{
            operation = 'executeQuery'
            query = $claimQuery
        }) -Credentials ([ordered]@{ postgres = [ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),

        (New-Node -Id 'ifClaimed' -Name 'Message Claimed?' -Type 'n8n-nodes-base.if' -TypeVersion 2 -Position @(1120,300) -Parameters ([ordered]@{
            conditions = [ordered]@{
                string = @([ordered]@{ value1='={{$json.id}}'; operation='isNotEmpty' })
            }
        })),

        (New-Node -Id 'sanitize' -Name 'Sanitize Input' -Type 'n8n-nodes-base.code' -TypeVersion 2 -Position @(1320,220) -Parameters ([ordered]@{
            mode = 'runOnceForEachItem'
            jsCode = @"
const payload = $json.payload || {};
const normalize = (v) => typeof v === 'string' ? v.replace(/\s+/g, ' ').trim().slice(0, 16000) : v;
const sanitized = JSON.parse(JSON.stringify(payload, (k, v) => (v === null ? undefined : normalize(v))));
return [{ json: { ...$json, sanitized } }];
"@
        })),

        (New-Node -Id 'split' -Name 'Split In Batches' -Type 'n8n-nodes-base.splitInBatches' -TypeVersion 3 -Position @(1520,220) -Parameters ([ordered]@{
            batchSize = '={{ Number($env.BATCH_SIZE || 10) }}'
            options = [ordered]@{}
        })),

        (New-Node -Id 'rateWait' -Name 'Rate Limit Wait' -Type 'n8n-nodes-base.wait' -TypeVersion 1.1 -Position @(1720,220) -Parameters ([ordered]@{
            amount = '={{ Number($env.RATE_LIMIT_DELAY_MS || 1200) }}'
            unit = 'milliseconds'
        })),

        (New-Node -Id 'claude' -Name 'Claude Analyze' -Type 'n8n-nodes-base.httpRequest' -TypeVersion 4.2 -Position @(1920,220) -Parameters ([ordered]@{
            method = 'POST'
            url = 'https://api.anthropic.com/v1/messages'
            sendHeaders = $true
            headerParameters = [ordered]@{
                parameters = @(
                    [ordered]@{ name='x-api-key'; value='={{$env.ANTHROPIC_API_KEY}}' },
                    [ordered]@{ name='anthropic-version'; value='2023-06-01' },
                    [ordered]@{ name='content-type'; value='application/json' }
                )
            }
            sendBody = $true
            contentType = 'json'
            specifyBody = 'json'
            jsonBody = '={{ {"model": $env.ANTHROPIC_MODEL || "claude-3-5-sonnet-latest", "max_tokens": Number($env.ANTHROPIC_MAX_TOKENS || 1600), "temperature": Number($env.ANTHROPIC_TEMPERATURE || 0.3), "top_p": 0.9, "system": $json.system_prompt, "messages": [{"role":"user","content":[{"type":"text","text": JSON.stringify($json.sanitized)}]}] } }}'
            options = [ordered]@{ timeout = 90000 }
        })),

        (New-Node -Id 'validate' -Name 'Validate JSON' -Type 'n8n-nodes-base.code' -TypeVersion 2 -Position @(2120,220) -Parameters ([ordered]@{
            mode = 'runOnceForEachItem'
            jsCode = @"
const txt = $json.content?.[0]?.text || $json.body?.content?.[0]?.text || '';
let parsed = null;
let valid = false;
let reason = '';
try {
  parsed = JSON.parse(txt);
  valid = parsed && typeof parsed === 'object';
} catch (e) {
  reason = e.message;
}
return [{ json: { ...$json, parsed, valid, validation_reason: reason } }];
"@
        })),

        (New-Node -Id 'ifValid' -Name 'Valid JSON?' -Type 'n8n-nodes-base.if' -TypeVersion 2 -Position @(2320,220) -Parameters ([ordered]@{
            conditions = [ordered]@{
                boolean = @([ordered]@{ value1='={{$json.valid}}'; operation='isTrue' })
            }
        })),

        (New-Node -Id 'writeAnalysis' -Name 'Write Analysis' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(2520,140) -Parameters ([ordered]@{
            operation = 'executeQuery'
            query = $analysisQuery
        }) -Credentials ([ordered]@{ postgres = [ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),

        (New-Node -Id 'writeBlackboard' -Name 'Write Blackboard' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(2720,140) -Parameters ([ordered]@{
            operation = 'executeQuery'
            query = $blackboardQuery
        }) -Credentials ([ordered]@{ postgres = [ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),

        (New-Node -Id 'postAnswer' -Name 'Post Answer' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(2920,140) -Parameters ([ordered]@{
            operation = 'executeQuery'
            query = $answerQuery
        }) -Credentials ([ordered]@{ postgres = [ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),

        (New-Node -Id 'markDone' -Name 'Mark Done' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(3120,140) -Parameters ([ordered]@{
            operation = 'executeQuery'
            query = $doneQuery
        }) -Credentials ([ordered]@{ postgres = [ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),

        (New-Node -Id 'repairPrompt' -Name 'Build Repair Prompt' -Type 'n8n-nodes-base.code' -TypeVersion 2 -Position @(2520,320) -Parameters ([ordered]@{
            mode = 'runOnceForEachItem'
            jsCode = 'const reason = $json.validation_reason || "invalid_json"; const prompt = `Return ONLY valid JSON matching schema. Fix: ${reason}`; return [{ json: { ...$json, repair_prompt: prompt } }];'
        })),

        (New-Node -Id 'claudeRepair' -Name 'Claude Repair' -Type 'n8n-nodes-base.httpRequest' -TypeVersion 4.2 -Position @(2720,320) -Parameters ([ordered]@{
            method = 'POST'
            url = 'https://api.anthropic.com/v1/messages'
            sendHeaders = $true
            headerParameters = [ordered]@{
                parameters = @(
                    [ordered]@{ name='x-api-key'; value='={{$env.ANTHROPIC_API_KEY}}' },
                    [ordered]@{ name='anthropic-version'; value='2023-06-01' },
                    [ordered]@{ name='content-type'; value='application/json' }
                )
            }
            sendBody = $true
            contentType = 'json'
            specifyBody = 'json'
            jsonBody = '={{ {"model": $env.ANTHROPIC_MODEL || "claude-3-5-sonnet-latest", "max_tokens": 800, "temperature": 0.2, "top_p": 0.9, "system": "Repair malformed JSON and return JSON only", "messages": [{"role":"user","content":[{"type":"text","text": $json.repair_prompt}]}] } }}'
        })),

        (New-Node -Id 'retryWait' -Name 'Retry Wait' -Type 'n8n-nodes-base.wait' -TypeVersion 1.1 -Position @(2920,320) -Parameters ([ordered]@{
            amount = '={{ Math.floor(Math.random() * Number($env.MESSAGE_RETRY_JITTER_MS || 2000)) + 1000 }}'
            unit = 'milliseconds'
        })),

        (New-Node -Id 'markFailed' -Name 'Mark Failed/Requeue' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(3120,320) -Parameters ([ordered]@{
            operation = 'executeQuery'
            query = $failQuery
        }) -Credentials ([ordered]@{ postgres = [ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),

        (New-Node -Id 'logIdle' -Name 'Log Idle' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(1320,420) -Parameters ([ordered]@{
            operation = 'executeQuery'
            query = $logNoMessageQuery
        }) -Credentials ([ordered]@{ postgres = [ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } }))
    )

    $connections = [ordered]@{
        'Cron Poll' = [ordered]@{ main = @(@([ordered]@{ node='Merge Trigger'; type='main'; index=0 })) }
        'Webhook Trigger' = [ordered]@{ main = @(@([ordered]@{ node='Merge Trigger'; type='main'; index=1 })) }
        'Merge Trigger' = [ordered]@{ main = @(@([ordered]@{ node='Set Config'; type='main'; index=0 })) }
    }

    if ($UseToggle) {
        $connections['Set Config'] = [ordered]@{ main = @(@([ordered]@{ node='Feature Enabled?'; type='main'; index=0 })) }
        $connections['Feature Enabled?'] = [ordered]@{ main = @(
            @([ordered]@{ node='Claim Message'; type='main'; index=0 }),
            @([ordered]@{ node='Log Idle'; type='main'; index=0 })
        ) }
    } else {
        $connections['Set Config'] = [ordered]@{ main = @(@([ordered]@{ node='Claim Message'; type='main'; index=0 })) }
    }

    $connections['Claim Message'] = [ordered]@{ main = @(@([ordered]@{ node='Message Claimed?'; type='main'; index=0 })) }
    $connections['Message Claimed?'] = [ordered]@{ main = @(
        @([ordered]@{ node='Sanitize Input'; type='main'; index=0 }),
        @([ordered]@{ node='Log Idle'; type='main'; index=0 })
    ) }
    $connections['Sanitize Input'] = [ordered]@{ main = @(@([ordered]@{ node='Split In Batches'; type='main'; index=0 })) }
    $connections['Split In Batches'] = [ordered]@{ main = @(
        @([ordered]@{ node='Rate Limit Wait'; type='main'; index=0 }),
        @()
    ) }
    $connections['Rate Limit Wait'] = [ordered]@{ main = @(@([ordered]@{ node='Claude Analyze'; type='main'; index=0 })) }
    $connections['Claude Analyze'] = [ordered]@{ main = @(@([ordered]@{ node='Validate JSON'; type='main'; index=0 })) }
    $connections['Validate JSON'] = [ordered]@{ main = @(@([ordered]@{ node='Valid JSON?'; type='main'; index=0 })) }
    $connections['Valid JSON?'] = [ordered]@{ main = @(
        @([ordered]@{ node='Write Analysis'; type='main'; index=0 }),
        @([ordered]@{ node='Build Repair Prompt'; type='main'; index=0 })
    ) }
    $connections['Write Analysis'] = [ordered]@{ main = @(@([ordered]@{ node='Write Blackboard'; type='main'; index=0 })) }
    $connections['Write Blackboard'] = [ordered]@{ main = @(@([ordered]@{ node='Post Answer'; type='main'; index=0 })) }
    $connections['Post Answer'] = [ordered]@{ main = @(@([ordered]@{ node='Mark Done'; type='main'; index=0 })) }
    $connections['Build Repair Prompt'] = [ordered]@{ main = @(@([ordered]@{ node='Claude Repair'; type='main'; index=0 })) }
    $connections['Claude Repair'] = [ordered]@{ main = @(@([ordered]@{ node='Retry Wait'; type='main'; index=0 })) }
    $connections['Retry Wait'] = [ordered]@{ main = @(@([ordered]@{ node='Mark Failed/Requeue'; type='main'; index=0 })) }

    return (New-Workflow -Id $Id -Name $Name -Nodes $nodes -Connections $connections)
}

$workflows = @()

# Coordinator workflow
$coordinatorNodes = @(
    (New-Node -Id 'cron' -Name 'Cron Trigger' -Type 'n8n-nodes-base.cron' -TypeVersion 1 -Position @(120,200) -Parameters ([ordered]@{
        triggerTimes = [ordered]@{ item = @([ordered]@{ mode='everyMinute' }) }
    })),
    (New-Node -Id 'webhook' -Name 'Webhook Trigger' -Type 'n8n-nodes-base.webhook' -TypeVersion 2 -Position @(120,360) -Parameters ([ordered]@{
        path='coordinator/trigger'
        httpMethod='POST'
        responseMode='onReceived'
        responseData='allEntries'
    })),
    (New-Node -Id 'merge' -Name 'Merge Trigger' -Type 'n8n-nodes-base.merge' -TypeVersion 3 -Position @(320,280) -Parameters ([ordered]@{ mode='append' })),
    (New-Node -Id 'claimTask' -Name 'Claim Task' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(520,280) -Parameters ([ordered]@{
        operation='executeQuery'
        query="UPDATE public.tasks SET status='running', updated_at=now() WHERE id=(SELECT id FROM public.tasks WHERE status='queued' ORDER BY created_at ASC FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING *;"
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'ifTask' -Name 'Task Claimed?' -Type 'n8n-nodes-base.if' -TypeVersion 2 -Position @(720,280) -Parameters ([ordered]@{
        conditions = [ordered]@{ string = @([ordered]@{ value1='={{$json.id}}'; operation='isNotEmpty' }) }
    })),
    (New-Node -Id 'createThread' -Name 'Create Thread' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(920,220) -Parameters ([ordered]@{
        operation='executeQuery'
        query="INSERT INTO public.agent_threads(task_id, topic, status, owner_agent) VALUES ({{$json.id}}, 'research', 'open', 'coordinator') RETURNING *;"
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'dispatch' -Name 'Dispatch Messages' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(1120,220) -Parameters ([ordered]@{
        operation='executeQuery'
        query=@"
INSERT INTO public.agent_messages(thread_id, task_id, from_agent, to_agent, kind, state, priority, payload)
VALUES
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'youtube_ingestion', 'task', 'queued', 3, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'twitter_ingestion', 'task', 'queued', 2, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'tiktok_ingestion', 'task', 'queued', 2, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'reddit_ingestion', 'task', 'queued', 2, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'meta_ads_ingestion', 'task', 'queued', 1, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'enrichment', 'task', 'queued', 3, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'creative_analyst', 'task', 'queued', 2, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'audience_persona', 'task', 'queued', 2, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'compliance_risk', 'task', 'queued', 2, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'performance_scoring', 'task', 'queued', 2, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'synthesis_insights', 'task', 'queued', 2, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'report_writer', 'task', 'queued', 1, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'qa_validator', 'task', 'queued', 1, {{$json}}),
({{$json.id}}, {{$json.task_id || $json.id}}, 'coordinator', 'notifier', 'task', 'queued', 1, {{$json}});
"@
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'logIdle' -Name 'Log Idle' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(920,380) -Parameters ([ordered]@{
        operation='executeQuery'
        query="INSERT INTO public.logs(level, agent, message, meta) VALUES ('debug','coordinator','no queued task','{}'::jsonb);"
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } }))
)

$coordinatorConnections = [ordered]@{
    'Cron Trigger' = [ordered]@{ main = @(@([ordered]@{ node='Merge Trigger'; type='main'; index=0 })) }
    'Webhook Trigger' = [ordered]@{ main = @(@([ordered]@{ node='Merge Trigger'; type='main'; index=1 })) }
    'Merge Trigger' = [ordered]@{ main = @(@([ordered]@{ node='Claim Task'; type='main'; index=0 })) }
    'Claim Task' = [ordered]@{ main = @(@([ordered]@{ node='Task Claimed?'; type='main'; index=0 })) }
    'Task Claimed?' = [ordered]@{ main = @(
        @([ordered]@{ node='Create Thread'; type='main'; index=0 }),
        @([ordered]@{ node='Log Idle'; type='main'; index=0 })
    ) }
    'Create Thread' = [ordered]@{ main = @(@([ordered]@{ node='Dispatch Messages'; type='main'; index=0 })) }
}

$workflows += (New-Workflow -Id 'wf-coordinator' -Name 'Coordinator (Task Router)' -Nodes $coordinatorNodes -Connections $coordinatorConnections)

# Ingestion + analysis agents
$workflows += (New-AgentWorkflow -Id 'wf-youtube' -Name 'YouTube Ingestion Agent' -AgentName 'youtube_ingestion' -SystemPrompt 'YouTube Data API v3 normalizer. Return strict JSON only.' -OutputKey 'youtube_ingestion.output')
$workflows += (New-AgentWorkflow -Id 'wf-twitter' -Name 'X/Twitter Ingestion Agent' -AgentName 'twitter_ingestion' -SystemPrompt 'X/Twitter v2 ingestion normalizer. Return strict JSON only.' -OutputKey 'twitter_ingestion.output' -UseToggle $true -ToggleEnv 'ENABLE_TWITTER')
$workflows += (New-AgentWorkflow -Id 'wf-tiktok' -Name 'TikTok Ingestion Agent' -AgentName 'tiktok_ingestion' -SystemPrompt 'Apify TikTok dataset normalizer. Return strict JSON only.' -OutputKey 'tiktok_ingestion.output' -UseToggle $true -ToggleEnv 'ENABLE_TIKTOK')
$workflows += (New-AgentWorkflow -Id 'wf-reddit' -Name 'Reddit Ingestion Agent' -AgentName 'reddit_ingestion' -SystemPrompt 'Reddit API ingestion normalizer. Return strict JSON only.' -OutputKey 'reddit_ingestion.output')
$workflows += (New-AgentWorkflow -Id 'wf-meta' -Name 'Meta Ad Library Agent' -AgentName 'meta_ads_ingestion' -SystemPrompt 'Meta Ad Library ingestion normalizer. Return strict JSON only.' -OutputKey 'meta_ads_ingestion.output' -UseToggle $true -ToggleEnv 'ENABLE_META_ADS')
$workflows += (New-AgentWorkflow -Id 'wf-enrichment' -Name 'Enrichment Agent' -AgentName 'enrichment' -SystemPrompt 'Normalize text, dedupe, canonical URLs, and language hints. Strict JSON only.' -OutputKey 'enrichment.output')
$workflows += (New-AgentWorkflow -Id 'wf-creative' -Name 'Creative Analyst Agent' -AgentName 'creative_analyst' -SystemPrompt 'Senior ad creative strategist. Output strict JSON per schema.' -OutputKey 'creative_analyst.output')
$workflows += (New-AgentWorkflow -Id 'wf-audience' -Name 'Audience & Persona Agent' -AgentName 'audience_persona' -SystemPrompt 'Marketing anthropologist. Output strict JSON with target_audience, reasons, topics, suggested_counter_angles, language.' -OutputKey 'audience_persona.output')
$workflows += (New-AgentWorkflow -Id 'wf-compliance' -Name 'Compliance & Risk Agent' -AgentName 'compliance_risk' -SystemPrompt 'Ad policy and brand safety reviewer. Output JSON with compliance_flags, brand_safety_risks, claims_summary, top_quote.' -OutputKey 'compliance_risk.output')
$workflows += (New-AgentWorkflow -Id 'wf-performance' -Name 'Performance Scoring Agent' -AgentName 'performance_scoring' -SystemPrompt 'Creative performance rater. Output JSON with quality_score, reasons, detected_format, emotional_tone, hook_style, cta_type.' -OutputKey 'performance_scoring.output')
$workflows += (New-AgentWorkflow -Id 'wf-synthesis' -Name 'Synthesis & Insights Agent' -AgentName 'synthesis_insights' -SystemPrompt 'Category strategist. Return JSON summary and markdown sections.' -OutputKey 'synthesis_insights.output')
$workflows += (New-AgentWorkflow -Id 'wf-report' -Name 'Report Writer Agent' -AgentName 'report_writer' -SystemPrompt 'Generate markdown, html, and JSON summary report. Strict JSON only.' -OutputKey 'report_writer.output')
$workflows += (New-AgentWorkflow -Id 'wf-qa' -Name 'QA/Validator Agent' -AgentName 'qa_validator' -SystemPrompt 'Validate schema compliance and request peer help when required. Strict JSON only.' -OutputKey 'qa_validator.output')
$workflows += (New-AgentWorkflow -Id 'wf-notifier' -Name 'Notifier Agent' -AgentName 'notifier' -SystemPrompt 'Create notification payloads for Slack and callbacks. Strict JSON only.' -OutputKey 'notifier.output')

# Extend Report Writer with Notion node
$report = $workflows | Where-Object { $_.name -eq 'Report Writer Agent' }
$report.nodes += (New-Node -Id 'notion' -Name 'Write Notion Report' -Type 'n8n-nodes-base.notion' -TypeVersion 2 -Position @(3320,140) -Parameters ([ordered]@{
    resource='page'
    operation='create'
    databaseId='={{$env.NOTION_DATABASE_ID}}'
    title='={{"Research Report - " + $json.task_id}}'
    propertiesUi=[ordered]@{
        propertyValues=@(
            [ordered]@{ key='Task ID'; type='rich_text'; richTextValue='={{$json.task_id}}' },
            [ordered]@{ key='Status'; type='select'; selectValue='Final' }
        )
    }
    content='={{$json.parsed.markdown || "No markdown generated"}}'
}) -Credentials ([ordered]@{ notionApi=[ordered]@{ id='notion-api'; name='Notion API' } }))
$report.connections['Mark Done'] = [ordered]@{ main = @(@([ordered]@{ node='Write Notion Report'; type='main'; index=0 })) }

# Extend Notifier with Slack + callback nodes
$notifier = $workflows | Where-Object { $_.name -eq 'Notifier Agent' }
$notifier.nodes += @(
    (New-Node -Id 'ifSlack' -Name 'Slack Enabled?' -Type 'n8n-nodes-base.if' -TypeVersion 2 -Position @(3320,120) -Parameters ([ordered]@{
        conditions=[ordered]@{ string=@([ordered]@{ value1='={{$env.ENABLE_SLACK}}'; operation='equal'; value2='true' }) }
    })),
    (New-Node -Id 'slack' -Name 'Send Slack' -Type 'n8n-nodes-base.slack' -TypeVersion 2.2 -Position @(3520,80) -Parameters ([ordered]@{
        resource='message'
        operation='post'
        channel='={{$env.SLACK_CHANNEL || "#research-alerts"}}'
        text='={{"Task " + $json.task_id + " completed"}}'
    }) -Credentials ([ordered]@{ slackApi=[ordered]@{ id='slack-api'; name='Slack API' } })),
    (New-Node -Id 'callback' -Name 'Webhook Callback' -Type 'n8n-nodes-base.httpRequest' -TypeVersion 4.2 -Position @(3520,180) -Parameters ([ordered]@{
        method='POST'
        url='={{$json.payload.notify_webhook || ""}}'
        sendBody=$true
        contentType='json'
        specifyBody='json'
        jsonBody='={{ {"task_id": $json.task_id, "status": "done"} }}'
        options=[ordered]@{ ignoreResponseCode=$true; timeout=10000 }
    }))
)
$notifier.connections['Mark Done'] = [ordered]@{ main = @(@([ordered]@{ node='Slack Enabled?'; type='main'; index=0 })) }
$notifier.connections['Slack Enabled?'] = [ordered]@{ main = @(
    @([ordered]@{ node='Send Slack'; type='main'; index=0 }),
    @([ordered]@{ node='Webhook Callback'; type='main'; index=0 })
) }
$notifier.connections['Send Slack'] = [ordered]@{ main = @(@([ordered]@{ node='Webhook Callback'; type='main'; index=0 })) }

# SaaS API workflow
$apiNodes = @(
    (New-Node -Id 'w1' -Name 'POST /v1/tasks/research' -Type 'n8n-nodes-base.webhook' -TypeVersion 2 -Position @(120,120) -Parameters ([ordered]@{ path='v1/tasks/research'; httpMethod='POST'; responseMode='responseNode' })),
    (New-Node -Id 'w2' -Name 'GET /v1/tasks/:task_id/status' -Type 'n8n-nodes-base.webhook' -TypeVersion 2 -Position @(120,240) -Parameters ([ordered]@{ path='v1/tasks/:task_id/status'; httpMethod='GET'; responseMode='responseNode' })),
    (New-Node -Id 'w3' -Name 'GET /v1/reports/:task_id' -Type 'n8n-nodes-base.webhook' -TypeVersion 2 -Position @(120,360) -Parameters ([ordered]@{ path='v1/reports/:task_id'; httpMethod='GET'; responseMode='responseNode' })),
    (New-Node -Id 'w4' -Name 'GET /v1/reports/latest' -Type 'n8n-nodes-base.webhook' -TypeVersion 2 -Position @(120,480) -Parameters ([ordered]@{ path='v1/reports/latest'; httpMethod='GET'; responseMode='responseNode' })),
    (New-Node -Id 'w5' -Name 'GET /v1/agents/threads' -Type 'n8n-nodes-base.webhook' -TypeVersion 2 -Position @(120,600) -Parameters ([ordered]@{ path='v1/agents/threads'; httpMethod='GET'; responseMode='responseNode' })),
    (New-Node -Id 'w6' -Name 'GET /v1/agents/threads/:thread_id/messages' -Type 'n8n-nodes-base.webhook' -TypeVersion 2 -Position @(120,720) -Parameters ([ordered]@{ path='v1/agents/threads/:thread_id/messages'; httpMethod='GET'; responseMode='responseNode' })),
    (New-Node -Id 'merge' -Name 'Merge Webhooks' -Type 'n8n-nodes-base.merge' -TypeVersion 3 -Position @(360,420) -Parameters ([ordered]@{ mode='append' })),
    (New-Node -Id 'auth' -Name 'Validate API Key' -Type 'n8n-nodes-base.code' -TypeVersion 2 -Position @(560,420) -Parameters ([ordered]@{
        mode='runOnceForEachItem'
        jsCode='const inKey = $json.headers?.["x-api-key"] || $json.headers?.["X-API-KEY"]; const ok = inKey && inKey === $env.SAAS_API_KEY; return [{ json: { ...$json, auth_ok: !!ok } }];'
    })),
    (New-Node -Id 'ifAuth' -Name 'Authorized?' -Type 'n8n-nodes-base.if' -TypeVersion 2 -Position @(760,420) -Parameters ([ordered]@{
        conditions=[ordered]@{ boolean=@([ordered]@{ value1='={{$json.auth_ok}}'; operation='isTrue' }) }
    })),
    (New-Node -Id 'route' -Name 'Route Path' -Type 'n8n-nodes-base.switch' -TypeVersion 3.2 -Position @(960,320) -Parameters ([ordered]@{
        mode='expression'
        output='={{$json.path}}'
        rules=@(
            [ordered]@{ operation='contains'; value='/v1/tasks/research' },
            [ordered]@{ operation='contains'; value='/status' },
            [ordered]@{ operation='contains'; value='/v1/reports/latest' },
            [ordered]@{ operation='contains'; value='/v1/reports/' },
            [ordered]@{ operation='contains'; value='/v1/agents/threads/' },
            [ordered]@{ operation='contains'; value='/v1/agents/threads' }
        )
    })),
    (New-Node -Id 'insertTask' -Name 'Insert Task' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(1160,120) -Parameters ([ordered]@{
        operation='executeQuery'
        query='INSERT INTO public.tasks(status, queries, competitors, platforms, date_range_start, date_range_end, max_items, language, notify_webhook) VALUES (''queued'', {{$json.body.queries || []}}, {{$json.body.competitors || []}}, {{$json.body.platforms || ["youtube"]}}, {{$json.body.date_range.start || null}}, {{$json.body.date_range.end || null}}, {{$json.body.max_items || Number($env.MAX_ITEMS_DEFAULT || 50)}}, {{$json.body.language || "en"}}, {{$json.body.notify_webhook || null}}) RETURNING *;'
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'taskStatus' -Name 'Get Task Status' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(1160,240) -Parameters ([ordered]@{
        operation='executeQuery'
        query='SELECT t.*, (SELECT count(*) FROM public.social_raw r WHERE r.task_id=t.id) AS raw_items_ingested, (SELECT count(*) FROM public.social_analysis a WHERE a.task_id=t.id) AS analyses_complete, (SELECT count(*)>0 FROM public.reports rp WHERE rp.task_id=t.id AND rp.status=''final'') AS report_ready FROM public.tasks t WHERE t.id={{$json.params.task_id}} LIMIT 1;'
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'reportByTask' -Name 'Get Report by Task' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(1160,360) -Parameters ([ordered]@{
        operation='executeQuery'
        query='SELECT * FROM public.reports WHERE task_id={{$json.params.task_id}} LIMIT 1;'
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'reportLatest' -Name 'Get Latest Report' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(1160,480) -Parameters ([ordered]@{
        operation='executeQuery'
        query='SELECT * FROM public.reports ORDER BY created_at DESC LIMIT 1;'
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'threads' -Name 'Get Threads' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(1160,600) -Parameters ([ordered]@{
        operation='executeQuery'
        query='SELECT * FROM public.agent_threads WHERE ({{$json.query.task_id || null}} IS NULL OR task_id={{$json.query.task_id || null}}) ORDER BY created_at DESC LIMIT 100;'
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'messages' -Name 'Get Thread Messages' -Type 'n8n-nodes-base.postgres' -TypeVersion 2.5 -Position @(1160,720) -Parameters ([ordered]@{
        operation='executeQuery'
        query='SELECT * FROM public.agent_messages WHERE thread_id={{$json.params.thread_id}} ORDER BY created_at ASC LIMIT 200;'
    }) -Credentials ([ordered]@{ postgres=[ordered]@{ id='supabase-postgres'; name='Supabase Postgres' } })),
    (New-Node -Id 'unauth' -Name 'Unauthorized Body' -Type 'n8n-nodes-base.set' -TypeVersion 3.4 -Position @(960,520) -Parameters ([ordered]@{
        assignments=[ordered]@{
            assignments=@(
                [ordered]@{ id='1'; name='statusCode'; type='number'; value=401 },
                [ordered]@{ id='2'; name='error'; type='string'; value='unauthorized' },
                [ordered]@{ id='3'; name='message'; type='string'; value='Missing or invalid x-api-key' }
            )
        }
    })),
    (New-Node -Id 'respond' -Name 'Respond' -Type 'n8n-nodes-base.respondToWebhook' -TypeVersion 1.2 -Position @(1360,420) -Parameters ([ordered]@{
        respondWith='json'
        responseBody='={{$json}}'
        options=[ordered]@{ responseCode='={{$json.statusCode || 200}}' }
    }))
)

$apiConnections = [ordered]@{
    'POST /v1/tasks/research' = [ordered]@{ main = @(@([ordered]@{ node='Merge Webhooks'; type='main'; index=0 })) }
    'GET /v1/tasks/:task_id/status' = [ordered]@{ main = @(@([ordered]@{ node='Merge Webhooks'; type='main'; index=1 })) }
    'GET /v1/reports/:task_id' = [ordered]@{ main = @(@([ordered]@{ node='Merge Webhooks'; type='main'; index=2 })) }
    'GET /v1/reports/latest' = [ordered]@{ main = @(@([ordered]@{ node='Merge Webhooks'; type='main'; index=3 })) }
    'GET /v1/agents/threads' = [ordered]@{ main = @(@([ordered]@{ node='Merge Webhooks'; type='main'; index=4 })) }
    'GET /v1/agents/threads/:thread_id/messages' = [ordered]@{ main = @(@([ordered]@{ node='Merge Webhooks'; type='main'; index=5 })) }
    'Merge Webhooks' = [ordered]@{ main = @(@([ordered]@{ node='Validate API Key'; type='main'; index=0 })) }
    'Validate API Key' = [ordered]@{ main = @(@([ordered]@{ node='Authorized?'; type='main'; index=0 })) }
    'Authorized?' = [ordered]@{ main = @(
        @([ordered]@{ node='Route Path'; type='main'; index=0 }),
        @([ordered]@{ node='Unauthorized Body'; type='main'; index=0 })
    ) }
    'Unauthorized Body' = [ordered]@{ main = @(@([ordered]@{ node='Respond'; type='main'; index=0 })) }
    'Route Path' = [ordered]@{ main = @(
        @([ordered]@{ node='Insert Task'; type='main'; index=0 }),
        @([ordered]@{ node='Get Task Status'; type='main'; index=0 }),
        @([ordered]@{ node='Get Latest Report'; type='main'; index=0 }),
        @([ordered]@{ node='Get Report by Task'; type='main'; index=0 }),
        @([ordered]@{ node='Get Thread Messages'; type='main'; index=0 }),
        @([ordered]@{ node='Get Threads'; type='main'; index=0 })
    ) }
    'Insert Task' = [ordered]@{ main = @(@([ordered]@{ node='Respond'; type='main'; index=0 })) }
    'Get Task Status' = [ordered]@{ main = @(@([ordered]@{ node='Respond'; type='main'; index=0 })) }
    'Get Report by Task' = [ordered]@{ main = @(@([ordered]@{ node='Respond'; type='main'; index=0 })) }
    'Get Latest Report' = [ordered]@{ main = @(@([ordered]@{ node='Respond'; type='main'; index=0 })) }
    'Get Threads' = [ordered]@{ main = @(@([ordered]@{ node='Respond'; type='main'; index=0 })) }
    'Get Thread Messages' = [ordered]@{ main = @(@([ordered]@{ node='Respond'; type='main'; index=0 })) }
}

$workflows += (New-Workflow -Id 'wf-saas-api' -Name 'SaaS API Workflow' -Nodes $apiNodes -Connections $apiConnections)

$outPath = Join-Path $PSScriptRoot 'n8n-export.json'
($workflows | ConvertTo-Json -Depth 100 -Compress) | Set-Content -Path $outPath -Encoding UTF8
Write-Output "Generated $($workflows.Count) workflows at $outPath"
