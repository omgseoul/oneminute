import assert from 'node:assert/strict';
import {allowedBuild} from '../supabase/functions/android-signing/authorization.mjs';
const good={repository:'omgseoul/oneminute',repository_id:'1191362253',repository_owner_id:'316879393',ref:'refs/heads/main',ref_type:'branch',workflow_ref:'omgseoul/oneminute/.github/workflows/build-android-apk.yml@refs/heads/main',event_name:'push',runner_environment:'github-hosted',jti:'valid-nonce',sha:'a'.repeat(40),run_id:'123'};
assert(allowedBuild(good));assert(allowedBuild({...good,event_name:'workflow_dispatch'}));
const calendar={...good,workflow_ref:'omgseoul/oneminute/.github/workflows/build-oms-calendar.yml@refs/heads/main'};
assert(allowedBuild(calendar));
assert(allowedBuild({...calendar,event_name:'workflow_dispatch'}));
for(const claims of [
 {...calendar,event_name:'pull_request'},
 {...calendar,event_name:'pull_request_target'},
 {...calendar,ref:'refs/heads/codex/oms-calendar'},
 {...calendar,workflow_ref:calendar.workflow_ref.replace('@refs/heads/main','@refs/pull/340/merge')},
 {...calendar,repository:'attacker/oneminute'},
 {...calendar,runner_environment:'self-hosted'}
])assert(!allowedBuild(claims),'Calendar signing must require the approved main workflow');
for(const [key,value] of [['repository','other/oneminute'],['repository_id','0'],['repository_owner_id','0'],['ref','refs/pull/123/merge'],['event_name','pull_request'],['workflow_ref','omgseoul/oneminute/.github/workflows/other.yml@refs/heads/main'],['runner_environment','self-hosted'],['sha','bad'],['jti',''],['run_id','foo']])assert(!allowedBuild({...good,[key]:value}),key);
console.log('PASS approved release claims and fork/PR/ref/workflow/repository/nonce rejection');
