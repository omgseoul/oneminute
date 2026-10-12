export function allowedBuild(claims) {
 return claims.repository==='omgseoul/oneminute' && String(claims.repository_id)==='1191362253'
 && String(claims.repository_owner_id)==='316879393'
 && claims.ref==='refs/heads/main' && claims.ref_type==='branch'
 && claims.workflow_ref==='omgseoul/oneminute/.github/workflows/build-android-apk.yml@refs/heads/main'
 && ['push','workflow_dispatch'].includes(claims.event_name)
 && claims.runner_environment==='github-hosted'
 && typeof claims.jti==='string' && claims.jti.length>0 && claims.jti.length<=200
 && /^[0-9a-f]{40}$/.test(claims.sha||'') && /^\d+$/.test(String(claims.run_id||''));
}
