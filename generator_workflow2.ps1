$ErrorActionPreference = 'Stop'

# ────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────
function N($id,$name,$type,$ver,$pos,$params,$creds=$null){
    $n=[ordered]@{id=$id;name=$name;type=$type;typeVersion=$ver;position=$pos;parameters=$params}
    if($creds){$n.credentials=$creds}
    return $n
}
function W($id,$name,$nodes,$conns){
    [ordered]@{id=$id;name=$name;active=$false;settings=[ordered]@{executionOrder='v1'};versionId="v-$id";pinData=[ordered]@{};tags=@();nodes=$nodes;connections=$conns}
}
$PG = [ordered]@{postgres=[ordered]@{id='supabase-postgres';name='Supabase Postgres'}}
$NOTION_CRED = [ordered]@{notionApi=[ordered]@{id='notion-api';name='Notion API'}}
$SLACK_CRED  = [ordered]@{slackApi=[ordered]@{id='slack-api';name='Slack API'}}

# ────────────────────────────────────────────────────────────
# SQL fragments used by all agents
# ────────────────────────────────────────────────────────────
function Get-Sqls($agent, $bbkey) {
    return @{
        # Atomic claim — uses partial index (state='queued') and marks claimed_at
        claim = @"
UPDATE public.agent_messages
SET state='claimed', attempts=attempts+1, claimed_at=now(), updated_at=now()
WHERE id=(
  SELECT id FROM public.agent_messages
  WHERE to_agent='$agent' AND state='queued'
  ORDER BY priority DESC, created_at ASC
  FOR UPDATE SKIP LOCKED LIMIT 1
) RETURNING *;
"@
        # Mark processing started
        inprogress = "UPDATE public.agent_messages SET state='in_progress', updated_at=now() WHERE id={{`$json.id}};"

        # Mark done with completed_at
        done = "UPDATE public.agent_messages SET state='done', completed_at=now(), updated_at=now() WHERE id={{`$json.id}};"

        # Requeue or fail; on final failure move to deadletter
        fail = @"
WITH upd AS (
  UPDATE public.agent_messages
  SET state=CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'queued' END,
      error={{`$json.err||'unknown'}}, updated_at=now()
  WHERE id={{`$json.id}}
  RETURNING *
)
INSERT INTO public.deadletter_messages(original_msg_id,task_id,thread_id,from_agent,to_agent,kind,payload,attempts,final_error)
SELECT id,task_id,thread_id,from_agent,to_agent,kind,payload,attempts,error
FROM upd WHERE state='failed';
"@
        # Write answer back to coordinator
        answer = "INSERT INTO public.agent_messages(thread_id,task_id,from_agent,to_agent,kind,state,priority,payload) VALUES ({{`$json.thread_id}},{{`$json.task_id}},'$agent','coordinator','answer','queued',1,{{`$json.parsed}});"

        # Upsert blackboard with versioning
        blackboard = @"
INSERT INTO public.blackboard(task_id,key,value,producer_agent,version)
VALUES ({{`$json.task_id}},'$bbkey',{{`$json.parsed}},'$agent',1)
ON CONFLICT (task_id,key) DO UPDATE
  SET value=EXCLUDED.value, producer_agent=EXCLUDED.producer_agent,
      version=blackboard.version+1, updated_at=now();
"@
        # Write analysis row
        analysis = @"
INSERT INTO public.social_analysis(
  task_id,agent,raw_llm_response,topics,creative_type,hook_style,target_audience,
  emotional_tone,compliance_flags,cta_type,claims_summary,quality_score,reasons,
  top_quote,hashtags,entities,suggested_counter_angles,brand_safety_risks,language,detected_format)
VALUES (
  {{`$json.task_id}},'$agent',{{`$json.parsed}},
  {{`$json.parsed.topics||[]}},{{`$json.parsed.creative_type||null}},{{`$json.parsed.hook_style||null}},
  {{`$json.parsed.target_audience||null}},{{`$json.parsed.emotional_tone||null}},
  {{`$json.parsed.compliance_flags||[]}},{{`$json.parsed.cta_type||null}},
  {{`$json.parsed.claims_summary||null}},{{`$json.parsed.quality_score||null}},
  {{`$json.parsed.reasons||null}},{{`$json.parsed.top_quote||null}},
  {{`$json.parsed.hashtags||[]}},{{`$json.parsed.entities||{}}},
  {{`$json.parsed.suggested_counter_angles||[]}},{{`$json.parsed.brand_safety_risks||[]}},
  {{`$json.parsed.language||null}},{{`$json.parsed.detected_format||null}});
"@
        # Record execution event at start
        evtStart = "INSERT INTO public.execution_events(task_id,agent,event_type,status,metadata) VALUES ({{`$json.task_id}},'$agent','message_claimed','success',{{`$json}});"

        # Record api_call_end event
        evtApiEnd = "INSERT INTO public.execution_events(task_id,agent,event_type,duration_ms,status) VALUES ({{`$json.task_id}},'$agent','api_call_end',{{`$json._api_ms||0}},'success');"

        # Record validation_fail event
        evtValFail = "INSERT INTO public.execution_events(task_id,agent,event_type,status,error_msg) VALUES ({{`$json.task_id}},'$agent','validation_fail','failure',{{`$json.validation_reason||'bad_json'}});"

        # Upsert agent metrics on done
        metrics = @"
INSERT INTO public.agent_metrics(task_id,agent,messages_processed,validation_passed,status)
VALUES ({{`$json.task_id}},'$agent',1,true,'completed')
ON CONFLICT (task_id,agent) DO UPDATE
  SET messages_processed=agent_metrics.messages_processed+1, status='completed', updated_at=now();
"@
        # Log idle
        idle = "INSERT INTO public.logs(level,agent,message,meta) VALUES ('debug','$agent','idle','{}'::jsonb);"

        # Rate limit log on 429
        rateLog = "INSERT INTO public.rate_limit_log(service,task_id,agent,was_throttled,backoff_ms) VALUES ('anthropic',{{`$json.task_id}},'$agent',true,{{`$json._backoff_ms||1200}});"
    }
}

# ────────────────────────────────────────────────────────────
# Agent workflow factory
# ────────────────────────────────────────────────────────────
function Agent($id,$name,$agent,$prompt,$bbkey,$toggle=$null) {
    $sq = Get-Sqls $agent $bbkey

    $sanitizeJs = @"
const payload = `$json.payload || {};
const clean = v => typeof v === 'string' ? v.replace(/\s+/g,' ').trim().slice(0,16000) : v;
const sanitized = JSON.parse(JSON.stringify(payload,(k,v) => v===null ? undefined : clean(v)));
const threadId  = `$json.thread_id  || null;
const taskId    = `$json.task_id    || null;
return [{ json: { ...`$json, sanitized, thread_id: threadId, task_id: taskId } }];
"@

    $parseJs = @"
const start   = `$json._api_start || Date.now();
const apiMs   = Date.now() - start;
const raw     = `$json.content?.[0]?.text || `$json.body?.content?.[0]?.text || '';
let parsed    = null, valid = false, reason = '';
try { parsed = JSON.parse(raw); valid = !!parsed && typeof parsed === 'object'; }
catch(e){ reason = e.message; }
return [{ json: { ...`$json, parsed, valid, validation_reason: reason, _api_ms: apiMs } }];
"@

    $repairJs = @"
const reason = `$json.validation_reason || 'invalid_json';
const prevText = `$json.content?.[0]?.text || `$json.body?.content?.[0]?.text || '';
return [{ json: { ...`$json, repair_prompt: `Strict JSON only. Schema:\n${JSON.stringify(`$json.expected_schema||{})}\n\nPrior output that failed:\n${prevText}\n\nError: ${reason}` } }];
"@

    $claudeBody = '={{{"model":$env.ANTHROPIC_MODEL||"claude-3-5-sonnet-latest","max_tokens":Number($env.ANTHROPIC_MAX_TOKENS||1600),"temperature":Number($env.ANTHROPIC_TEMPERATURE||0.3),"top_p":0.9,"system":$json.system_prompt,"messages":[{"role":"user","content":[{"type":"text","text":JSON.stringify($json.sanitized)}]}]}}}'
    $claudeRepairBody = '={{{"model":$env.ANTHROPIC_MODEL||"claude-3-5-sonnet-latest","max_tokens":600,"temperature":0.1,"system":"Return valid JSON only, no markdown fences.","messages":[{"role":"user","content":[{"type":"text","text":$json.repair_prompt}]}]}}}'

    $claudeHeaders = @{
        parameters = @(
            [ordered]@{name='x-api-key';value='={{$env.ANTHROPIC_API_KEY}}'},
            [ordered]@{name='anthropic-version';value='2023-06-01'},
            [ordered]@{name='content-type';value='application/json'}
        )
    }

    # Rate-limit check after Claude call
    $rateLimitJs = @"
const status = `$json.statusCode || `$json.status || 200;
const isRateLimit = status === 429 || status === 503;
const backoff = isRateLimit
  ? (Number(((`$json.headers||{})['retry-after']||0))*1000 || Number(`$env.RATE_LIMIT_DELAY_MS||1200))
  : Number(`$env.RATE_LIMIT_DELAY_MS||1200);
return [{ json: { ...`$json, _is_rate_limited: isRateLimit, _backoff_ms: backoff, _api_start: Date.now() } }];
"@

    # build nodes list
    $nodes = @(
        (N 'cron'      'Cron'       'n8n-nodes-base.cron'    1   @(100,180) ([ordered]@{triggerTimes=[ordered]@{item=@([ordered]@{mode='everyMinute'})}})),
        (N 'wh'        'Webhook'    'n8n-nodes-base.webhook' 2   @(100,320) ([ordered]@{path="agent/$agent/trigger";httpMethod='POST';responseMode='onReceived';responseData='allEntries'})),
        (N 'mg'        'Merge'      'n8n-nodes-base.merge'   3   @(260,250) ([ordered]@{mode='append'})),
        (N 'cfg'       'Set Config' 'n8n-nodes-base.set'     3.4 @(420,250) ([ordered]@{assignments=[ordered]@{assignments=@([ordered]@{id='1';name='system_prompt';type='string';value=$prompt},[ordered]@{id='2';name='expected_schema';type='json';value='{"topics":"array","creative_type":"string","hook_style":"string","target_audience":"string","emotional_tone":"string","compliance_flags":"array","cta_type":"string","claims_summary":"string","quality_score":"integer","reasons":"string","top_quote":"string","hashtags":"array","entities":"object","suggested_counter_angles":"array","brand_safety_risks":"array","language":"string","detected_format":"string"}'})};options=[ordered]@{}}))
    )

    if ($toggle) {
        $nodes += (N 'tog' 'Feature Enabled?' 'n8n-nodes-base.if' 2 @(580,250) ([ordered]@{conditions=[ordered]@{string=@([ordered]@{value1="={{`$env.$toggle}}";operation='equal';value2='true'})}}))
    }

    $nodes += @(
        (N 'claim'     'Claim Message'       'n8n-nodes-base.postgres'      2.5  @(740,180)  ([ordered]@{operation='executeQuery';query=$sq.claim})             $PG),
        (N 'ifClaim'   'Has Message?'        'n8n-nodes-base.if'            2    @(900,180)  ([ordered]@{conditions=[ordered]@{string=@([ordered]@{value1='={{$json.id}}';operation='isNotEmpty'})}})),
        (N 'markIP'    'Mark In-Progress'    'n8n-nodes-base.postgres'      2.5  @(1060,100) ([ordered]@{operation='executeQuery';query=$sq.inprogress})         $PG),
        (N 'evtStart'  'Log Claimed Event'   'n8n-nodes-base.postgres'      2.5  @(1220,100) ([ordered]@{operation='executeQuery';query=$sq.evtStart})           $PG),
        (N 'sanit'     'Sanitize Input'      'n8n-nodes-base.code'          2    @(1380,100) ([ordered]@{mode='runOnceForEachItem';jsCode=$sanitizeJs})),
        (N 'split'     'Split Batches'       'n8n-nodes-base.splitInBatches' 3   @(1540,100) ([ordered]@{batchSize='={{Number($env.BATCH_SIZE||10)}}';options=[ordered]@{}})),
        (N 'rlWait'    'Rate Limit Wait'     'n8n-nodes-base.wait'          1.1  @(1700,100) ([ordered]@{amount='={{Number($env.RATE_LIMIT_DELAY_MS||1200)}}';unit='milliseconds'})),
        (N 'tsStart'   'Timestamp Start'     'n8n-nodes-base.set'           3.4  @(1860,100) ([ordered]@{assignments=[ordered]@{assignments=@([ordered]@{id='1';name='_api_start';type='number';value='={{Date.now()}}'})};options=[ordered]@{}})),
        (N 'claude'    'Claude API'          'n8n-nodes-base.httpRequest'   4.2  @(2020,100) ([ordered]@{method='POST';url='https://api.anthropic.com/v1/messages';sendHeaders=$true;headerParameters=$claudeHeaders;sendBody=$true;contentType='json';specifyBody='json';jsonBody=$claudeBody;options=[ordered]@{timeout=90000;response=[ordered]@{response=[ordered]@{responseFormat='json';fullResponse=$true}}}})),
        (N 'rlCheck'   'Rate Limit Check'    'n8n-nodes-base.code'          2    @(2180,100) ([ordered]@{mode='runOnceForEachItem';jsCode=$rateLimitJs})),
        (N 'ifRL'      'Rate Limited?'       'n8n-nodes-base.if'            2    @(2340,100) ([ordered]@{conditions=[ordered]@{boolean=@([ordered]@{value1='={{$json._is_rate_limited}}';operation='isTrue'})}})),
        (N 'rlLog'     'Log Rate Limit'      'n8n-nodes-base.postgres'      2.5  @(2500,40)  ([ordered]@{operation='executeQuery';query=$sq.rateLog})            $PG),
        (N 'rlBackoff' 'Backoff Wait'        'n8n-nodes-base.wait'          1.1  @(2660,40)  ([ordered]@{amount='={{$json._backoff_ms||1200}}';unit='milliseconds'})),
        (N 'parse'     'Parse + Time'        'n8n-nodes-base.code'          2    @(2500,180) ([ordered]@{mode='runOnceForEachItem';jsCode=$parseJs})),
        (N 'evtApi'    'Log API Event'       'n8n-nodes-base.postgres'      2.5  @(2660,180) ([ordered]@{operation='executeQuery';query=$sq.evtApiEnd})          $PG),
        (N 'ifValid'   'Valid JSON?'          'n8n-nodes-base.if'            2    @(2820,180) ([ordered]@{conditions=[ordered]@{boolean=@([ordered]@{value1='={{$json.valid}}';operation='isTrue'})}})),
        (N 'writeA'    'Write Analysis'      'n8n-nodes-base.postgres'      2.5  @(2980,100) ([ordered]@{operation='executeQuery';query=$sq.analysis})          $PG),
        (N 'writeBB'   'Write Blackboard'    'n8n-nodes-base.postgres'      2.5  @(3140,100) ([ordered]@{operation='executeQuery';query=$sq.blackboard})        $PG),
        (N 'postAns'   'Post Answer'         'n8n-nodes-base.postgres'      2.5  @(3300,100) ([ordered]@{operation='executeQuery';query=$sq.answer})            $PG),
        (N 'metrics'   'Write Metrics'       'n8n-nodes-base.postgres'      2.5  @(3460,100) ([ordered]@{operation='executeQuery';query=$sq.metrics})           $PG),
        (N 'done'      'Mark Done'           'n8n-nodes-base.postgres'      2.5  @(3620,100) ([ordered]@{operation='executeQuery';query=$sq.done})              $PG),
        (N 'evtFail'   'Log Validation Fail' 'n8n-nodes-base.postgres'      2.5  @(2980,280) ([ordered]@{operation='executeQuery';query=$sq.evtValFail})        $PG),
        (N 'repair'    'Build Repair Prompt' 'n8n-nodes-base.code'          2    @(3140,280) ([ordered]@{mode='runOnceForEachItem';jsCode=$repairJs})),
        (N 'claudeR'   'Claude Repair'       'n8n-nodes-base.httpRequest'   4.2  @(3300,280) ([ordered]@{method='POST';url='https://api.anthropic.com/v1/messages';sendHeaders=$true;headerParameters=$claudeHeaders;sendBody=$true;contentType='json';specifyBody='json';jsonBody=$claudeRepairBody;options=[ordered]@{timeout=30000}})),
        (N 'retryW'    'Retry Wait'          'n8n-nodes-base.wait'          1.1  @(3460,280) ([ordered]@{amount='={{Math.floor(Math.random()*Number($env.MESSAGE_RETRY_JITTER_MS||2000))+500}}';unit='milliseconds'})),
        (N 'fail'      'Fail / Deadletter'   'n8n-nodes-base.postgres'      2.5  @(3620,280) ([ordered]@{operation='executeQuery';query=$sq.fail})              $PG),
        (N 'idle'      'Log Idle'            'n8n-nodes-base.postgres'      2.5  @(1060,300) ([ordered]@{operation='executeQuery';query=$sq.idle})              $PG)
    )

    # Build connection map
    $c = [ordered]@{
        'Cron'              = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=0}))}
        'Webhook'           = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=1}))}
        'Merge'             = [ordered]@{main=@(@([ordered]@{node='Set Config';type='main';index=0}))}
    }
    if ($toggle) {
        $c['Set Config']          = [ordered]@{main=@(@([ordered]@{node='Feature Enabled?';type='main';index=0}))}
        $c['Feature Enabled?']    = [ordered]@{main=@(@([ordered]@{node='Claim Message';type='main';index=0}),@([ordered]@{node='Log Idle';type='main';index=0}))}
    } else {
        $c['Set Config']          = [ordered]@{main=@(@([ordered]@{node='Claim Message';type='main';index=0}))}
    }
    $c['Claim Message']           = [ordered]@{main=@(@([ordered]@{node='Has Message?';type='main';index=0}))}
    $c['Has Message?']            = [ordered]@{main=@(@([ordered]@{node='Mark In-Progress';type='main';index=0}),@([ordered]@{node='Log Idle';type='main';index=0}))}
    $c['Mark In-Progress']        = [ordered]@{main=@(@([ordered]@{node='Log Claimed Event';type='main';index=0}))}
    $c['Log Claimed Event']       = [ordered]@{main=@(@([ordered]@{node='Sanitize Input';type='main';index=0}))}
    $c['Sanitize Input']          = [ordered]@{main=@(@([ordered]@{node='Split Batches';type='main';index=0}))}
    $c['Split Batches']           = [ordered]@{main=@(@([ordered]@{node='Rate Limit Wait';type='main';index=0}),@())}
    $c['Rate Limit Wait']         = [ordered]@{main=@(@([ordered]@{node='Timestamp Start';type='main';index=0}))}
    $c['Timestamp Start']         = [ordered]@{main=@(@([ordered]@{node='Claude API';type='main';index=0}))}
    $c['Claude API']              = [ordered]@{main=@(@([ordered]@{node='Rate Limit Check';type='main';index=0}))}
    $c['Rate Limit Check']        = [ordered]@{main=@(@([ordered]@{node='Rate Limited?';type='main';index=0}))}
    $c['Rate Limited?']           = [ordered]@{main=@(@([ordered]@{node='Log Rate Limit';type='main';index=0}),@([ordered]@{node='Parse + Time';type='main';index=0}))}
    $c['Log Rate Limit']          = [ordered]@{main=@(@([ordered]@{node='Backoff Wait';type='main';index=0}))}
    $c['Backoff Wait']            = [ordered]@{main=@(@([ordered]@{node='Claude API';type='main';index=0}))}
    $c['Parse + Time']            = [ordered]@{main=@(@([ordered]@{node='Log API Event';type='main';index=0}))}
    $c['Log API Event']           = [ordered]@{main=@(@([ordered]@{node='Valid JSON?';type='main';index=0}))}
    $c['Valid JSON?']             = [ordered]@{main=@(@([ordered]@{node='Write Analysis';type='main';index=0}),@([ordered]@{node='Log Validation Fail';type='main';index=0}))}
    $c['Write Analysis']          = [ordered]@{main=@(@([ordered]@{node='Write Blackboard';type='main';index=0}))}
    $c['Write Blackboard']        = [ordered]@{main=@(@([ordered]@{node='Post Answer';type='main';index=0}))}
    $c['Post Answer']             = [ordered]@{main=@(@([ordered]@{node='Write Metrics';type='main';index=0}))}
    $c['Write Metrics']           = [ordered]@{main=@(@([ordered]@{node='Mark Done';type='main';index=0}))}
    $c['Log Validation Fail']     = [ordered]@{main=@(@([ordered]@{node='Build Repair Prompt';type='main';index=0}))}
    $c['Build Repair Prompt']     = [ordered]@{main=@(@([ordered]@{node='Claude Repair';type='main';index=0}))}
    $c['Claude Repair']           = [ordered]@{main=@(@([ordered]@{node='Retry Wait';type='main';index=0}))}
    $c['Retry Wait']              = [ordered]@{main=@(@([ordered]@{node='Fail / Deadletter';type='main';index=0}))}

    W $id $name $nodes $c
}

# ────────────────────────────────────────────────────────────
# BUILD WORKFLOWS
# ────────────────────────────────────────────────────────────
$all = @()

# ── 1. COORDINATOR ──────────────────────────────────────────
# STAGE-GATED DISPATCH
# Stage 1 (priority 3): ingestion agents only — coordinator dispatches these immediately.
# Stage 2 (priority 2): analysis agents — Stage Gate workflow watches for ingestion
#   completion and inserts these messages, preventing analysis from running on empty data.
$dispatchJs = @"
const platforms = (`$json.platforms || ['youtube']).map(p => p.toLowerCase());
const toggles = {
  twitter:  `$env.ENABLE_TWITTER  === 'true',
  tiktok:   `$env.ENABLE_TIKTOK   === 'true',
  reddit:   true,
  meta_ads: `$env.ENABLE_META_ADS === 'true',
  youtube:  true,
};
const enabled = platforms.filter(p => toggles[p] !== false);
// Stage 1 only: ingestion agents
const rows = enabled.map(p => ({
  thread_id  : `$json._thread_id,
  task_id    : `$json.id,
  from_agent : 'coordinator',
  to_agent   : `${p}_ingestion`,
  kind       : 'task',
  state      : 'queued',
  priority   : 3,
  payload    : `$json
}));
// Write expected ingestion agents to blackboard so Stage Gate knows what to wait for
return [{ json: { ..`$json, _thread_id: `$json._thread_id, _ingestion_agents: enabled.map(p=>`${p}_ingestion`), _dispatch_rows: rows } }];
"@

$coordNodes = @(
    (N 'cron'     'Cron'             'n8n-nodes-base.cron'        1   @(100,160) ([ordered]@{triggerTimes=[ordered]@{item=@([ordered]@{mode='everyMinute'})}})),
    (N 'wh'       'Webhook'          'n8n-nodes-base.webhook'     2   @(100,280) ([ordered]@{path='coordinator/trigger';httpMethod='POST';responseMode='onReceived';responseData='allEntries'})),
    (N 'mg'       'Merge'            'n8n-nodes-base.merge'       3   @(260,220) ([ordered]@{mode='append'})),
    (N 'claim'    'Claim Task'       'n8n-nodes-base.postgres'    2.5 @(420,220) ([ordered]@{operation='executeQuery';query="UPDATE public.tasks SET status='running',updated_at=now() WHERE id=(SELECT id FROM public.tasks WHERE status='queued' ORDER BY created_at ASC FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING *;"}) $PG),
    (N 'ifTask'   'Task Found?'      'n8n-nodes-base.if'          2   @(600,220) ([ordered]@{conditions=[ordered]@{string=@([ordered]@{value1='={{$json.id}}';operation='isNotEmpty'})}})),
    (N 'thread'   'Create Thread'    'n8n-nodes-base.postgres'    2.5 @(760,140) ([ordered]@{operation='executeQuery';query="INSERT INTO public.agent_threads(task_id,topic,status,owner_agent) VALUES ({{`$json.id}},'research','open','coordinator') RETURNING id;"}) $PG),
    (N 'setThr'   'Attach Thread ID' 'n8n-nodes-base.set'         3.4 @(920,140) ([ordered]@{assignments=[ordered]@{assignments=@([ordered]@{id='1';name='_thread_id';type='string';value='={{$json[0].id}}'})};options=[ordered]@{}})),
    (N 'dispatch' 'Build Dispatches' 'n8n-nodes-base.code'        2   @(1080,140) ([ordered]@{mode='runOnceForAllItems';jsCode=$dispatchJs})),
    (N 'insert'   'Insert Messages'  'n8n-nodes-base.postgres'    2.5 @(1260,140) ([ordered]@{operation='insert';schema='public';table='agent_messages';columns='thread_id,task_id,from_agent,to_agent,kind,state,priority,payload';options=[ordered]@{}) $PG),
    (N 'progLog'  'Log Task Start'   'n8n-nodes-base.postgres'    2.5 @(1420,140) ([ordered]@{operation='executeQuery';query="INSERT INTO public.logs(level,agent,task_id,message,meta) VALUES ('info','coordinator',{{`$json.task_id}},'task_dispatched',{{`$json}});"}) $PG),
    # Write which ingestion agents are expected, so Stage Gate can check completion
    (N 'bbStage'   'BB: Ingestion Expected' 'n8n-nodes-base.postgres' 2.5 @(1580,140) ([ordered]@{operation='executeQuery';query="INSERT INTO public.blackboard(task_id,key,value,producer_agent) VALUES ({{`$json.id}},'stage_gate.expected_ingestion',{{`$json._ingestion_agents||[]}},'coordinator') ON CONFLICT (task_id,key) DO UPDATE SET value=EXCLUDED.value,updated_at=now();"}) $PG),
    (N 'idle'     'Log Idle'         'n8n-nodes-base.postgres'    2.5 @(760,320) ([ordered]@{operation='executeQuery';query="INSERT INTO public.logs(level,agent,message,meta) VALUES ('debug','coordinator','idle','{}'::jsonb);"}) $PG),
    # SLA monitor — finds tasks running > 30 min and re-dispatches failed messages
    (N 'sla'      'SLA Monitor'      'n8n-nodes-base.postgres'    2.5 @(1600,140) ([ordered]@{operation='executeQuery';query="UPDATE public.tasks SET status='failed',error='sla_exceeded',updated_at=now() WHERE status='running' AND updated_at < now()-interval '30 minutes' RETURNING id;"}) $PG)
)
$coordConn = [ordered]@{
    'Cron'             = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=0}))}
    'Webhook'          = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=1}))}
    'Merge'            = [ordered]@{main=@(@([ordered]@{node='Claim Task';type='main';index=0}))}
    'Claim Task'       = [ordered]@{main=@(@([ordered]@{node='Task Found?';type='main';index=0}))}
    'Task Found?'      = [ordered]@{main=@(@([ordered]@{node='Create Thread';type='main';index=0}),@([ordered]@{node='Log Idle';type='main';index=0}))}
    'Create Thread'    = [ordered]@{main=@(@([ordered]@{node='Attach Thread ID';type='main';index=0}))}
    'Attach Thread ID' = [ordered]@{main=@(@([ordered]@{node='Build Dispatches';type='main';index=0}))}
    'Build Dispatches' = [ordered]@{main=@(@([ordered]@{node='Insert Messages';type='main';index=0}))}
    'Insert Messages'  = [ordered]@{main=@(@([ordered]@{node='Log Task Start';type='main';index=0}))}
    'Log Task Start'          = [ordered]@{main=@(@([ordered]@{node='BB: Ingestion Expected';type='main';index=0}))}
    'BB: Ingestion Expected'   = [ordered]@{main=@(@([ordered]@{node='SLA Monitor';type='main';index=0}))}
}
$all += W 'wf-coordinator' 'Coordinator (Task Router)' $coordNodes $coordConn

# ── 2–6. INGESTION AGENTS ───────────────────────────────────
$all += Agent 'wf-youtube'  'YouTube Ingestion Agent'    'youtube_ingestion'    'YouTube Data API v3 metadata and comments normalizer. Extract: title, description, author, published_at, tags, video_id, view_count, like_count, comment_count, thumbnail_url, canonical_url. Return strict JSON matching schema exactly. No markdown, no explanation, JSON only.' 'youtube_ingestion.output'
$all += Agent 'wf-twitter'  'X/Twitter Ingestion Agent'  'twitter_ingestion'    'X/Twitter v2 Recent Search result normalizer. Extract: tweet_id, author, text, created_at, metrics, hashtags, urls, media. Return strict JSON matching schema. JSON only.' 'twitter_ingestion.output' 'ENABLE_TWITTER'
$all += Agent 'wf-tiktok'   'TikTok Ingestion Agent'     'tiktok_ingestion'     'Apify TikTok scraper output normalizer. Extract: video_id, author, description, published_at, play_count, like_count, comment_count, share_count, hashtags, music, url. Strict JSON only.' 'tiktok_ingestion.output' 'ENABLE_TIKTOK'
$all += Agent 'wf-reddit'   'Reddit Ingestion Agent'     'reddit_ingestion'     'Reddit API post/comment normalizer. Extract: post_id, subreddit, author, title, body, score, upvote_ratio, num_comments, url, created_at, flair. Strict JSON only.' 'reddit_ingestion.output'
$all += Agent 'wf-meta'     'Meta Ad Library Agent'      'meta_ads_ingestion'   'Meta Ad Library result normalizer. Extract: ad_id, page_name, ad_creative_body, ad_delivery_start, ad_delivery_stop, impressions, spend, region_distribution, demographic_distribution. Strict JSON only.' 'meta_ads_ingestion.output' 'ENABLE_META_ADS'

# ── 7. ENRICHMENT ───────────────────────────────────────────
$all += Agent 'wf-enrichment' 'Enrichment Agent' 'enrichment' 'Text enrichment specialist. For each item: normalize whitespace and unicode, detect language (BCP-47), extract canonical URL, generate dedupe_key=sha256(platform+":"+native_id), strip HTML. Return strict JSON with fields: cleaned_text, language, canonical_url, dedupe_key, word_count, detected_entities. JSON only.' 'enrichment.output'

# ── 8–12. ANALYSIS AGENTS ───────────────────────────────────
$all += Agent 'wf-creative'     'Creative Analyst Agent'      'creative_analyst'    'Senior ad creative strategist. Analyze creative assets for: hook type (question/stat/story/shock), CTA style (soft/hard/implicit), narrative arc, visual format signal, emotional trigger, and angle uniqueness. Return strict JSON per schema. quality_score reflects creative strength 0-100. JSON only.'    'creative_analyst.output'
$all += Agent 'wf-audience'     'Audience & Persona Agent'    'audience_persona'    'Marketing anthropologist. Infer: target_audience demographics and psychographics, JTBD (Jobs To Be Done), awareness stage (unaware/problem-aware/solution-aware/product-aware/most-aware), top objections, and 3 suggested counter-angles. Return strict JSON. JSON only.'                                    'audience_persona.output'
$all += Agent 'wf-compliance'   'Compliance & Risk Agent'     'compliance_risk'     'Ad policy and brand safety expert. Flag: unsubstantiated claims, before/after comparisons, guarantee language, competitor disparagement, sensitive categories (health/finance/political), brand safety risks (violence/adult/hate). List top verbatim quote that is most risky. Return strict JSON. JSON only.' 'compliance_risk.output'
$all += Agent 'wf-performance'  'Performance Scoring Agent'   'performance_scoring' 'Creative performance rater. Score 0-100 overall quality. Assess: hook_strength (1-10), clarity (1-10), emotional_resonance (1-10), cta_effectiveness (1-10). Identify top distribution tactic (paid/organic/influencer/SEO). Return strict JSON. JSON only.'                                              'performance_scoring.output'
$all += Agent 'wf-synthesis'    'Synthesis & Insights Agent'  'synthesis_insights'  'Category strategist. Aggregate cross-platform insights into: top_trends (array), whitespace_opportunities (array), dominant_formats (array), most_effective_hooks (array), competitor_weaknesses (array), recommended_angles (array), executive_summary (string). Return strict JSON. JSON only.'            'synthesis_insights.output'

# ── 13. REPORT WRITER ──────────────────────────────────────
$all += Agent 'wf-report' 'Report Writer Agent' 'report_writer' 'Senior marketing analyst and report writer. Read all blackboard data for the task and generate a comprehensive research report. Return strict JSON with fields: title (string), executive_summary (string), markdown (full markdown report with sections), json_summary (object with top_trends, whitespace_opportunities, top_performers, compliance_alerts). JSON only.' 'report_writer.output'

# Patch Report Writer: add DB report upsert + Notion write before Mark Done
$rw = $all | Where-Object { $_.name -eq 'Report Writer Agent' }

$rw.nodes += @(
    (N 'rptUpsert' 'Upsert Report' 'n8n-nodes-base.postgres' 2.5 @(3780,100) ([ordered]@{operation='executeQuery';query=@"
INSERT INTO public.reports(task_id,status,title,markdown,html,json_summary)
VALUES ({{`$json.task_id}},'draft',{{`$json.parsed.title||'Report'}},{{`$json.parsed.markdown||''}},{{`$json.parsed.html||''}},{{`$json.parsed.json_summary||{}}})
ON CONFLICT (task_id) DO UPDATE
  SET status='draft',title=EXCLUDED.title,markdown=EXCLUDED.markdown,
      html=EXCLUDED.html,json_summary=EXCLUDED.json_summary,updated_at=now()
RETURNING id;
"@}) $PG),

    (N 'ifNotion' 'Notion Enabled?' 'n8n-nodes-base.if' 2 @(3940,100) ([ordered]@{conditions=[ordered]@{string=@([ordered]@{value1='={{$env.ENABLE_NOTION||"true"}}';operation='equal';value2='true'})}})),

    (N 'notion' 'Create Notion Page' 'n8n-nodes-base.notion' 2 @(4100,60) ([ordered]@{
        resource='page'; operation='create'
        databaseId='={{$env.NOTION_DATABASE_ID}}'
        title='={{$json.parsed.title || "Research Report - " + $json.task_id}}'
        propertiesUi=[ordered]@{propertyValues=@(
            [ordered]@{key='Task ID';type='rich_text';richTextValue='={{$json.task_id}}'},
            [ordered]@{key='Status';type='select';selectValue='Final'},
            [ordered]@{key='Platforms';type='rich_text';richTextValue='={{(($json.payload||{}).platforms||[]).join(", ")}}'},
            [ordered]@{key='Created';type='date';dateValue='={{new Date().toISOString()}}'}
        )}
        content='={{$json.parsed.markdown||"No content generated"}}'
    }) $NOTION_CRED),

    (N 'notionBack' 'Save Notion Link' 'n8n-nodes-base.postgres' 2.5 @(4260,60) ([ordered]@{operation='executeQuery';query="UPDATE public.reports SET notion_page_id={{`$json.id}},notion_url={{`$json.url||null}},status='final',updated_at=now() WHERE task_id={{`$json._task_id}};"}) $PG),
    (N 'setTaskId'  'Pass Task ID'     'n8n-nodes-base.set'       3.4 @(4100,140) ([ordered]@{assignments=[ordered]@{assignments=@([ordered]@{id='1';name='_skip_notion';type='boolean';value=$true})};options=[ordered]@{}}))
)

# Patch Report Writer connections
$rw.connections['Write Metrics']      = [ordered]@{main=@(@([ordered]@{node='Upsert Report';type='main';index=0}))}
$rw.connections['Upsert Report']      = [ordered]@{main=@(@([ordered]@{node='Notion Enabled?';type='main';index=0}))}
$rw.connections['Notion Enabled?']    = [ordered]@{main=@(@([ordered]@{node='Create Notion Page';type='main';index=0}),@([ordered]@{node='Pass Task ID';type='main';index=0}))}
$rw.connections['Create Notion Page'] = [ordered]@{main=@(@([ordered]@{node='Save Notion Link';type='main';index=0}))}
$rw.connections['Save Notion Link']   = [ordered]@{main=@(@([ordered]@{node='Mark Done';type='main';index=0}))}
$rw.connections['Pass Task ID']       = [ordered]@{main=@(@([ordered]@{node='Mark Done';type='main';index=0}))}

# ── 14. QA / VALIDATOR ──────────────────────────────────────
$all += Agent 'wf-qa' 'QA/Validator Agent' 'qa_validator' 'Output schema validator and quality gate. Compare each analysis record against expected schema. Check: all required fields present, quality_score is integer 0-100, compliance_flags is array, no null required fields. Return strict JSON with fields: passed (boolean), failed_fields (array), recommendations (array), overall_verdict (string). JSON only.' 'qa_validator.output'

# ── 15. NOTIFIER ────────────────────────────────────────────
$all += Agent 'wf-notifier' 'Notifier Agent' 'notifier' 'Notification payload builder. Read task summary from blackboard and create concise notification. Return strict JSON with fields: subject (string), body (string), task_id (string), report_url (string|null), summary (object with 3 bullet points). JSON only.' 'notifier.output'

# Patch Notifier: add Slack + callback webhook after Mark Done
$nt = $all | Where-Object { $_.name -eq 'Notifier Agent' }
$nt.nodes += @(
    (N 'ifSlack'  'Slack Enabled?'    'n8n-nodes-base.if'          2   @(3780,100) ([ordered]@{conditions=[ordered]@{string=@([ordered]@{value1='={{$env.ENABLE_SLACK||"false"}}';operation='equal';value2='true'})}})),
    (N 'slack'    'Slack Message'     'n8n-nodes-base.slack'        2.2 @(3940,60)  ([ordered]@{resource='message';operation='post';channel='={{$env.SLACK_CHANNEL||"#research-alerts"}}';text='={{$json.parsed.subject + "\n" + $json.parsed.body}}'}) $SLACK_CRED),
    (N 'cbWait'   'Check Webhook URL' 'n8n-nodes-base.if'           2   @(3940,160) ([ordered]@{conditions=[ordered]@{string=@([ordered]@{value1='={{($json.payload||{}).notify_webhook||""}}';operation='isNotEmpty'})}})),
    (N 'callback' 'POST Callback'     'n8n-nodes-base.httpRequest'  4.2 @(4100,160) ([ordered]@{method='POST';url='={{($json.payload||{}).notify_webhook}}';sendBody=$true;contentType='json';specifyBody='json';jsonBody='={{{"task_id":$json.task_id,"status":"done","report_url":$json.parsed.report_url||null,"summary":$json.parsed.summary}}}';options=[ordered]@{timeout=10000;ignoreResponseCode=$true}})),
    (N 'doneTask' 'Mark Task Done'    'n8n-nodes-base.postgres'     2.5 @(4260,120) ([ordered]@{operation='executeQuery';query="UPDATE public.tasks SET status='done',updated_at=now() WHERE id={{`$json.task_id}};"}) $PG)
)
$nt.connections['Mark Done']     = [ordered]@{main=@(@([ordered]@{node='Slack Enabled?';type='main';index=0}))}
$nt.connections['Slack Enabled?']= [ordered]@{main=@(@([ordered]@{node='Slack Message';type='main';index=0}),@([ordered]@{node='Check Webhook URL';type='main';index=0}))}
$nt.connections['Slack Message'] = [ordered]@{main=@(@([ordered]@{node='Check Webhook URL';type='main';index=0}))}
$nt.connections['Check Webhook URL'] = [ordered]@{main=@(@([ordered]@{node='POST Callback';type='main';index=0}),@([ordered]@{node='Mark Task Done';type='main';index=0}))}
$nt.connections['POST Callback'] = [ordered]@{main=@(@([ordered]@{node='Mark Task Done';type='main';index=0}))}

# ── 16. SaaS API ─────────────────────────────────────────────
$apiNodes = @(
    (N 'w1' 'POST /v1/tasks/research'                      'n8n-nodes-base.webhook' 2 @(100,80)  ([ordered]@{path='v1/tasks/research';httpMethod='POST';responseMode='responseNode'})),
    (N 'w2' 'GET /v1/tasks/:task_id/status'                'n8n-nodes-base.webhook' 2 @(100,160) ([ordered]@{path='v1/tasks/:task_id/status';httpMethod='GET';responseMode='responseNode'})),
    (N 'w3' 'GET /v1/reports/:task_id'                     'n8n-nodes-base.webhook' 2 @(100,240) ([ordered]@{path='v1/reports/:task_id';httpMethod='GET';responseMode='responseNode'})),
    (N 'w4' 'GET /v1/reports/latest'                       'n8n-nodes-base.webhook' 2 @(100,320) ([ordered]@{path='v1/reports/latest';httpMethod='GET';responseMode='responseNode'})),
    (N 'w5' 'GET /v1/agents/threads'                       'n8n-nodes-base.webhook' 2 @(100,400) ([ordered]@{path='v1/agents/threads';httpMethod='GET';responseMode='responseNode'})),
    (N 'w6' 'GET /v1/agents/threads/:thread_id/messages'   'n8n-nodes-base.webhook' 2 @(100,480) ([ordered]@{path='v1/agents/threads/:thread_id/messages';httpMethod='GET';responseMode='responseNode'})),
    (N 'mg'  'Merge'           'n8n-nodes-base.merge'      3   @(280,280) ([ordered]@{mode='append'})),
    (N 'auth' 'Auth Check'     'n8n-nodes-base.code'       2   @(440,280) ([ordered]@{mode='runOnceForEachItem';jsCode='const k=($json.headers||{})["x-api-key"]||($json.headers||{})["X-API-KEY"];return [{json:{...$json,_ok:!!k&&k===$env.SAAS_API_KEY,_path:$json.path||""}}];'})),
    (N 'ifA'  'Authorized?'    'n8n-nodes-base.if'         2   @(600,280) ([ordered]@{conditions=[ordered]@{boolean=@([ordered]@{value1='={{$json._ok}}';operation='isTrue'})}})),
    (N 'rt'   'Route Path'     'n8n-nodes-base.switch'     3.2 @(760,200) ([ordered]@{mode='expression';output='={{$json._path}}';rules=@([ordered]@{operation='contains';value='/v1/tasks/research'},[ordered]@{operation='contains';value='/status'},[ordered]@{operation='contains';value='/v1/reports/latest'},[ordered]@{operation='contains';value='/v1/reports/'},[ordered]@{operation='contains';value='/v1/agents/threads/'},[ordered]@{operation='contains';value='/v1/agents/threads'})})),

    # ── Query nodes ────────────────────────
    (N 'q1' 'Insert Task'           'n8n-nodes-base.postgres' 2.5 @(940,60)  ([ordered]@{operation='executeQuery';query='INSERT INTO public.tasks(status,queries,competitors,platforms,date_range_start,date_range_end,max_items,language,notify_webhook) VALUES (''queued'',{{$json.body.queries||[]}},{{$json.body.competitors||[]}},{{$json.body.platforms||["youtube"]}},{{$json.body.date_range.start||null}},{{$json.body.date_range.end||null}},{{$json.body.max_items||Number($env.MAX_ITEMS_DEFAULT||50)}},{{$json.body.language||"en"}},{{$json.body.notify_webhook||null}}) RETURNING id,status,created_at;'}) $PG),
    # Uses vw_task_summary view for rich status
    (N 'q2' 'Task Status'           'n8n-nodes-base.postgres' 2.5 @(940,140) ([ordered]@{operation='executeQuery';query='SELECT * FROM public.vw_task_summary WHERE id={{$json.params.task_id}};'}) $PG),
    (N 'q3' 'Report by Task'        'n8n-nodes-base.postgres' 2.5 @(940,220) ([ordered]@{operation='executeQuery';query='SELECT id,task_id,status,title,markdown,html,json_summary,notion_url,created_at,updated_at FROM public.reports WHERE task_id={{$json.params.task_id}} LIMIT 1;'}) $PG),
    (N 'q4' 'Latest Report'         'n8n-nodes-base.postgres' 2.5 @(940,300) ([ordered]@{operation='executeQuery';query='SELECT id,task_id,status,title,json_summary,notion_url,created_at FROM public.reports WHERE status=''final'' ORDER BY created_at DESC LIMIT 1;'}) $PG),
    (N 'q5' 'Threads Query'         'n8n-nodes-base.postgres' 2.5 @(940,380) ([ordered]@{operation='executeQuery';query='SELECT * FROM public.agent_threads WHERE ({{$json.query.task_id||null}} IS NULL OR task_id={{$json.query.task_id||null}}) ORDER BY created_at DESC LIMIT 100;'}) $PG),
    (N 'q6' 'Thread Messages'       'n8n-nodes-base.postgres' 2.5 @(940,460) ([ordered]@{operation='executeQuery';query='SELECT id,from_agent,to_agent,kind,state,attempts,error,created_at,updated_at FROM public.agent_messages WHERE thread_id={{$json.params.thread_id}} ORDER BY created_at ASC LIMIT 200;'}) $PG),

    # Shape responses
    (N 'fmt1' 'Shape Task Created'  'n8n-nodes-base.set' 3.4 @(1100,60)  ([ordered]@{assignments=[ordered]@{assignments=@([ordered]@{id='1';name='task_id';type='string';value='={{$json[0].id}}'}, [ordered]@{id='2';name='status';type='string';value='={{$json[0].status}}'}, [ordered]@{id='3';name='created_at';type='string';value='={{$json[0].created_at}}'}, [ordered]@{id='4';name='message';type='string';value='Multi-agent job queued'})};options=[ordered]@{}})),
    (N 'fmt2' 'Shape Status'        'n8n-nodes-base.set' 3.4 @(1100,140) ([ordered]@{assignments=[ordered]@{assignments=@([ordered]@{id='1';name='data';type='json';value='={{$json[0]||{}}}'},  [ordered]@{id='2';name='report_ready';type='boolean';value='={{($json[0]||{}).report_count>0}}'})};options=[ordered]@{}})),

    (N 'u'    'Unauthorized'        'n8n-nodes-base.set'      3.4 @(760,360) ([ordered]@{assignments=[ordered]@{assignments=@([ordered]@{id='1';name='statusCode';type='number';value=401},[ordered]@{id='2';name='error';type='string';value='unauthorized'},[ordered]@{id='3';name='message';type='string';value='Invalid or missing x-api-key'})}})),
    (N 'resp' 'Respond'             'n8n-nodes-base.respondToWebhook' 1.2 @(1280,280) ([ordered]@{respondWith='json';responseBody='={{$json}}';options=[ordered]@{responseCode='={{$json.statusCode||200}}'}}))
)

$apiConn = [ordered]@{
    'POST /v1/tasks/research'                    = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=0}))}
    'GET /v1/tasks/:task_id/status'              = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=1}))}
    'GET /v1/reports/:task_id'                   = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=2}))}
    'GET /v1/reports/latest'                     = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=3}))}
    'GET /v1/agents/threads'                     = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=4}))}
    'GET /v1/agents/threads/:thread_id/messages' = [ordered]@{main=@(@([ordered]@{node='Merge';type='main';index=5}))}
    'Merge'        = [ordered]@{main=@(@([ordered]@{node='Auth Check';type='main';index=0}))}
    'Auth Check'   = [ordered]@{main=@(@([ordered]@{node='Authorized?';type='main';index=0}))}
    'Authorized?'  = [ordered]@{main=@(@([ordered]@{node='Route Path';type='main';index=0}),@([ordered]@{node='Unauthorized';type='main';index=0}))}
    'Unauthorized' = [ordered]@{main=@(@([ordered]@{node='Respond';type='main';index=0}))}
    'Route Path'   = [ordered]@{main=@(
        @([ordered]@{node='Insert Task';type='main';index=0}),
        @([ordered]@{node='Task Status';type='main';index=0}),
        @([ordered]@{node='Latest Report';type='main';index=0}),
        @([ordered]@{node='Report by Task';type='main';index=0}),
        @([ordered]@{node='Thread Messages';type='main';index=0}),
        @([ordered]@{node='Threads Query';type='main';index=0})
    )}
    'Insert Task'    = [ordered]@{main=@(@([ordered]@{node='Shape Task Created';type='main';index=0}))}
    'Task Status'    = [ordered]@{main=@(@([ordered]@{node='Shape Status';type='main';index=0}))}
    'Report by Task' = [ordered]@{main=@(@([ordered]@{node='Respond';type='main';index=0}))}
    'Latest Report'  = [ordered]@{main=@(@([ordered]@{node='Respond';type='main';index=0}))}
    'Threads Query'  = [ordered]@{main=@(@([ordered]@{node='Respond';type='main';index=0}))}
    'Thread Messages'= [ordered]@{main=@(@([ordered]@{node='Respond';type='main';index=0}))}
    'Shape Task Created'= [ordered]@{main=@(@([ordered]@{node='Respond';type='main';index=0}))}
    'Shape Status'   = [ordered]@{main=@(@([ordered]@{node='Respond';type='main';index=0}))}
}
$all += W 'wf-saas-api' 'SaaS API Workflow' $apiNodes $apiConn

# ── STAGE GATE AGENT ────────────────────────────────────────
# Polls every 30s; when ALL ingestion agents for a task have written to blackboard,
# dispatches the full analysis pipeline as Stage 2 messages.
$sgCheckJs = @"
const rows = `$items;
const pending = rows.filter(r => {
  const expected = (r.json.expected || []);
  const done     = (r.json.done_agents || '').split(',').filter(Boolean);
  const allDone  = expected.length > 0 && expected.every(a => done.includes(a));
  const alreadyGated = r.json.already_gated;
  return allDone && !alreadyGated;
});
return pending.map(r => ({ json: r.json }));
"@

$sgDispatchJs = @"
const analysts = [
  'enrichment','creative_analyst','audience_persona','compliance_risk',
  'performance_scoring','synthesis_insights','vision_analyst','trend_monitor',
  'competitor_intel','keyword_seo','report_writer','qa_validator','notifier'
];
const rows = analysts.map(a => ({
  thread_id  : `$json.thread_id,
  task_id    : `$json.task_id,
  from_agent : 'stage_gate',
  to_agent   : a,
  kind       : 'task',
  state      : 'queued',
  priority   : 2,
  payload    : `$json
}));
return rows.map(r => ({ json: r }));
"@

$sgNodes = @(
  (N 'cron'   'Cron 30s'          'n8n-nodes-base.cron'    1   @(100,160) ([ordered]@{triggerTimes=[ordered]@{item=@([ordered]@{mode='everyX';unit='seconds';value=30})}})),
  (N 'query'  'Find Ready Tasks'  'n8n-nodes-base.postgres' 2.5 @(300,160) ([ordered]@{
    operation='executeQuery'
    query=@"
SELECT
  t.id AS task_id,
  t.status,
  bb_exp.value::jsonb   AS expected,
  bb_done.value::text   AS done_agents,
  bb_gate.id IS NOT NULL AS already_gated
FROM public.tasks t
JOIN public.blackboard bb_exp
  ON bb_exp.task_id=t.id AND bb_exp.key='stage_gate.expected_ingestion'
LEFT JOIN public.blackboard bb_done
  ON bb_done.task_id=t.id AND bb_done.key='stage_gate.ingestion_done_list'
LEFT JOIN public.blackboard bb_gate
  ON bb_gate.task_id=t.id AND bb_gate.key='stage_gate.analysis_dispatched'
WHERE t.status='running'
ORDER BY t.created_at ASC
LIMIT 20;
"@
  }) $PG),
  (N 'check'  'Filter Ready'      'n8n-nodes-base.code'     2   @(500,160) ([ordered]@{mode='runOnceForAllItems';jsCode=$sgCheckJs})),
  (N 'ifRdy'  'Any Ready?'        'n8n-nodes-base.if'       2   @(680,160) ([ordered]@{conditions=[ordered]@{number=@([ordered]@{value1='={{$items.length}}';operation='larger';value2=0})}})),
  (N 'lockBB' 'Lock Stage Gate'   'n8n-nodes-base.postgres' 2.5 @(840,100) ([ordered]@{
    operation='executeQuery'
    query="INSERT INTO public.blackboard(task_id,key,value,producer_agent) VALUES ({{`$json.task_id}},'stage_gate.analysis_dispatched',{{true}},'stage_gate') ON CONFLICT (task_id,key) DO NOTHING RETURNING task_id;"
  }) $PG),
  (N 'ifLock' 'Got Lock?'         'n8n-nodes-base.if'       2   @(1000,100) ([ordered]@{conditions=[ordered]@{string=@([ordered]@{value1='={{$json.task_id}}';operation='isNotEmpty'})}})),
  (N 'thread' 'Get Thread ID'     'n8n-nodes-base.postgres' 2.5 @(1160,100) ([ordered]@{
    operation='executeQuery'
    query="SELECT id AS thread_id FROM public.agent_threads WHERE task_id={{`$json.task_id}} AND owner_agent='coordinator' LIMIT 1;"
  }) $PG),
  (N 'build'  'Build Dispatch'    'n8n-nodes-base.code'     2   @(1320,100) ([ordered]@{mode='runOnceForAllItems';jsCode=$sgDispatchJs})),
  (N 'insert' 'Insert Stage 2'    'n8n-nodes-base.postgres' 2.5 @(1480,100) ([ordered]@{operation='insert';schema='public';table='agent_messages';columns='thread_id,task_id,from_agent,to_agent,kind,state,priority,payload';options=[ordered]@{}}) $PG),
  (N 'logSG'  'Log Stage 2 Start' 'n8n-nodes-base.postgres' 2.5 @(1640,100) ([ordered]@{operation='executeQuery';query="INSERT INTO public.logs(level,agent,task_id,message) VALUES ('info','stage_gate',{{`$json.task_id}},'analysis_stage_dispatched');"}) $PG),
  (N 'idle'   'Log Idle'          'n8n-nodes-base.postgres' 2.5 @(840,240) ([ordered]@{operation='executeQuery';query="INSERT INTO public.logs(level,agent,message,meta) VALUES ('debug','stage_gate','idle','{}'::jsonb);"}) $PG)
)
$sgConn = [ordered]@{
  'Cron 30s'         = [ordered]@{main=@(@([ordered]@{node='Find Ready Tasks';type='main';index=0}))}
  'Find Ready Tasks' = [ordered]@{main=@(@([ordered]@{node='Filter Ready';type='main';index=0}))}
  'Filter Ready'     = [ordered]@{main=@(@([ordered]@{node='Any Ready?';type='main';index=0}))}
  'Any Ready?'       = [ordered]@{main=@(@([ordered]@{node='Lock Stage Gate';type='main';index=0}),@([ordered]@{node='Log Idle';type='main';index=0}))}
  'Lock Stage Gate'  = [ordered]@{main=@(@([ordered]@{node='Got Lock?';type='main';index=0}))}
  'Got Lock?'        = [ordered]@{main=@(@([ordered]@{node='Get Thread ID';type='main';index=0}),@([ordered]@{node='Log Idle';type='main';index=0}))}
  'Get Thread ID'    = [ordered]@{main=@(@([ordered]@{node='Build Dispatch';type='main';index=0}))}
  'Build Dispatch'   = [ordered]@{main=@(@([ordered]@{node='Insert Stage 2';type='main';index=0}))}
  'Insert Stage 2'   = [ordered]@{main=@(@([ordered]@{node='Log Stage 2 Start';type='main';index=0}))}
}
$all += W 'wf-stage-gate' 'Stage Gate Agent' $sgNodes $sgConn

# ── INGESTION DONE REPORTER ──────────────────────────────────
# Each ingestion agent already writes to blackboard — Stage Gate needs a union list.
# This inlined helper is appended at the end of each ingestion agent's 'Mark Done' chain.
# We patch each ingestion workflow to also update the cumulative done-list on blackboard.
foreach ($wfName in @('YouTube Ingestion Agent','X/Twitter Ingestion Agent','TikTok Ingestion Agent','Reddit Ingestion Agent','Meta Ad Library Agent')) {
  $wf = $all | Where-Object { $_.name -eq $wfName }
  if (-not $wf) { continue }
  $agentToken = switch ($wfName) {
    'YouTube Ingestion Agent'   { 'youtube_ingestion' }
    'X/Twitter Ingestion Agent' { 'twitter_ingestion' }
    'TikTok Ingestion Agent'    { 'tiktok_ingestion' }
    'Reddit Ingestion Agent'    { 'reddit_ingestion' }
    'Meta Ad Library Agent'     { 'meta_ads_ingestion' }
  }
  $updateDoneList = @"
INSERT INTO public.blackboard(task_id,key,value,producer_agent)
VALUES ({{`$json.task_id}},'stage_gate.ingestion_done_list',
  to_jsonb(COALESCE((SELECT value::text FROM public.blackboard
    WHERE task_id={{`$json.task_id}} AND key='stage_gate.ingestion_done_list'),'') || ',$agentToken'),
  'stage_gate')
ON CONFLICT (task_id,key) DO UPDATE
  SET value=to_jsonb(COALESCE(blackboard.value::text,'') || ',$agentToken'), updated_at=now();
"@
  $nodeId = "sgDone_$agentToken"
  $wf.nodes += (N $nodeId 'Update Done List' 'n8n-nodes-base.postgres' 2.5 @(3800,100) ([ordered]@{operation='executeQuery';query=$updateDoneList}) $PG)
  # Redirect existing 'Mark Done' output to new node, which then calls old Mark Done
  $wf.connections['Write Metrics']    = [ordered]@{main=@(@([ordered]@{node='Update Done List';type='main';index=0}))}
  $wf.connections['Update Done List'] = [ordered]@{main=@(@([ordered]@{node='Mark Done';type='main';index=0}))}
}

# ── VISION ANALYST AGENT ─────────────────────────────────────
$all += Agent 'wf-vision' 'Vision Analyst Agent' 'vision_analyst' @'
You are a visual content analyst with expertise in ad creatives and social media thumbnails.
You receive thumbnail URLs and titles. Analyze the visual strategy:
- dominant_colors: array of hex codes or color names
- composition_type: rule-of-thirds / centered / split / text-heavy
- text_overlay: is there text on image? what does it say?
- face_present: boolean
- emotion_conveyed: array of emotions
- visual_hook_strength: 1-10 score
- cta_visible: boolean
- brand_elements: array of detected logos/brands
- accessibility_score: 1-10 (contrast, readability)
- improvement_suggestions: array of strings
Return strict JSON only. No markdown, no explanation.
'@ 'vision_analyst.output'

# Patch Vision agent to use Claude vision (pass thumbnail_url as image content)
$va = $all | Where-Object { $_.name -eq 'Vision Analyst Agent' }
$visionBody = @'
={{
  {
    model: $env.ANTHROPIC_MODEL||"claude-3-5-sonnet-latest",
    max_tokens: Number($env.ANTHROPIC_MAX_TOKENS||1200),
    temperature: Number($env.ANTHROPIC_TEMPERATURE||0.3),
    system: $json.system_prompt,
    messages: [{
      role: "user",
      content: [
        {
          type: "image",
          source: {
            type: "url",
            url: $json.sanitized.thumbnail_url || $json.sanitized.url || ""
          }
        },
        {
          type: "text",
          text: "Analyze this image. Context: " + JSON.stringify({title:$json.sanitized.title,platform:$json.sanitized.platform})
        }
      ]
    }]
  }
}}
'@
# Find the Claude API node and update the body
$claudeNode = $va.nodes | Where-Object { $_.name -eq 'Claude API' }
if ($claudeNode) { $claudeNode.parameters.jsonBody = $visionBody }

# ── TREND MONITOR AGENT ──────────────────────────────────────
$all += Agent 'wf-trend' 'Trend Monitor Agent' 'trend_monitor' @'
You are a trend detection analyst specializing in social media virality patterns.
Analyze the provided batch of social items and identify:
- trending_topics: array of topics showing momentum (with platform and spike_score 1-10)
- viral_signals: array of posts with unusual engagement (with native_id, platform, signal_type)
- emerging_formats: new content formats appearing this week
- peak_times: when engagement spikes (day/hour patterns if detectable)
- velocity_trend: "rising" | "stable" | "declining" for each top topic
- trend_summary: 1-paragraph executive summary of what is trending and why
Return strict JSON only. No markdown, no explanation.
'@ 'trend_monitor.output'

# ── COMPETITOR INTEL AGENT ───────────────────────────────────
$all += Agent 'wf-competitor' 'Competitor Intel Agent' 'competitor_intel' @'
You are a competitive intelligence analyst. You receive social content and a list of competitor brands.
For each competitor mentioned, analyze:
- competitor_name: string
- mention_count: integer
- sentiment: "positive" | "neutral" | "negative"
- key_messages: array of their main talking points
- ad_angles: array of creative angles they are using
- weaknesses_signaled: array of weaknesses consumers mention
- engagement_vs_avg: "above" | "at" | "below" average
- threat_level: "high" | "medium" | "low"
Return JSON object with key competitors (array of above objects) and gap_opportunities (array of strings).
Strict JSON only. No markdown, no explanation.
'@ 'competitor_intel.output'

# ── KEYWORD & SEO AGENT ──────────────────────────────────────
$all += Agent 'wf-keyword' 'Keyword & SEO Agent' 'keyword_seo' @'
You are a search and SEO strategist. Analyze the provided social content batch and extract:
- top_keywords: array of {keyword, frequency, search_intent (informational|commercial|transactional), volume_signal (high|medium|low)}
- long_tail_phrases: array of 3-6 word phrases with strong buying intent
- negative_keywords: irrelevant high-frequency terms to exclude from campaigns
- semantic_clusters: object mapping cluster names to arrays of related terms
- hashtag_strategy: array of {tag, platform, reach_score 1-10, competition_score 1-10}
- content_gap_keywords: terms competitors rank for that the client does not appear to target
- recommended_titles: array of 5 SEO-optimized title templates using top keywords
Return strict JSON only. No markdown, no explanation.
'@ 'keyword_seo.output'

# ── OUTPUT ──────────────────────────────────────────────────
$out = Join-Path $PSScriptRoot 'n8n-export.json'
($all | ConvertTo-Json -Depth 100 -Compress) | Set-Content $out -Encoding UTF8

# Split into individual importable files
$dir = Join-Path $PSScriptRoot 'workflows'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
foreach ($wf in $all) {
    $safe = $wf.name -replace '[^\w\-]','_'
    ($wf | ConvertTo-Json -Depth 100 -Compress) | Set-Content "$dir/$safe.json" -Encoding UTF8
}

Write-Output "Generated $($all.Count) workflows"
Write-Output "Combined : $out ($([math]::Round((Get-Item $out).Length/1KB))KB)"
Write-Output "Per-file : $dir/"
