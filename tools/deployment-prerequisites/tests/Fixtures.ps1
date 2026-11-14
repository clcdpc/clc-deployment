function New-ValidationConfig {
    @{
        Repository='example/app'; EnvironmentName='app-dev'; IntegrationBranch='master';
        ReleaseWorkflow='.github/workflows/release.yml'; DeploymentWorkflow='.github/workflows/deploy-release.yml';
        RunnerGroup='app-deployment'; RunnerLabels='self-hosted,Windows,X64'; ActivationVariable='CLC_DEPLOYMENT_ENABLED';
        DeploymentChannel='DEV'; ActivationState='enabled'; ApplicationId='app';TargetId='app-dev';SharedRevision=('a'*40);DiagnosticWorkflow='.github/workflows/diagnose.yml'
    }
}

function New-ApiSuccess($Data) { @{ ok=$true; code=200; data=$Data; reason='' } }
function New-ApiFailure([int] $Code=403) { @{ ok=$false; code=$Code; reason='Administrative API access unavailable.' } }
function New-WorkflowFile([string] $Text) {
    New-ApiSuccess @{ type='file'; encoding='base64'; size=[Text.Encoding]::UTF8.GetByteCount($Text); content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
}

function New-ValidationFixture {
    $release=@'
name: Release
on:
  push:
    tags: ['v*']
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: clcdpc/clc-deployment/.github/workflows/example.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
'@
    $deploy=@'
name: Deploy
on:
  workflow_run:
    workflows: [Release]
    types: [completed]
  workflow_dispatch:
jobs:
  publication:
    uses: clcdpc/clc-deployment/.github/workflows/application-release.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  deployment:
    uses: clcdpc/clc-deployment/.github/workflows/application-deploy.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    with:
      automatic: ${{ github.event_name != 'workflow_dispatch' }}
'@
    $fixture=@{
        '/repos/example/app'=(New-ApiSuccess @{ visibility='private'; private=$true; full_name='example/app' })
        '/repos/example/app/branches/master'=(New-ApiSuccess @{ protected=$true; commit=@{ sha=('b'*40) } })
        '/repos/example/app/branches/master/protection'=(New-ApiSuccess @{
            required_pull_request_reviews=@{ required_approving_review_count=1; require_code_owner_reviews=$true }
            enforce_admins=@{enabled=$true};required_status_checks=@{contexts=@('CI');checks=@()};
            allow_force_pushes=@{ enabled=$false }; allow_deletions=@{ enabled=$false }
        })
        '/repos/example/app/rules/branches/master'=(New-ApiSuccess @())
        '/repos/example/app/rulesets?includes_parents=true'=(New-ApiSuccess @(@{ id=12 }))
        '/repos/example/app/rulesets/12?includes_parents=true'=(New-ApiSuccess @{
            target='tag'; enforcement='active'; name='Misleading names are not evidence'
            conditions=@{ ref_name=@{ include=@('refs/tags/v*'); exclude=@() } }
            rules=@(@{ type='creation' },@{ type='update' },@{ type='deletion' })
            bypass_actors=@(@{ actor_type='Integration'; actor_id=1; bypass_mode='always' })
        })
        ('/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40))=(New-WorkflowFile $release)
        ('/repos/example/app/contents/.github/workflows/deploy-release.yml?ref='+('b'*40))=(New-WorkflowFile $deploy)
        '/repos/example/app/environments'=(New-ApiSuccess @{ environments=@(@{ name='app-dev' }); total_count=1 })
        '/repos/example/app/environments/app-dev'=(New-ApiSuccess @{
            name='app-dev'; deployment_branch_policy=@{ protected_branches=$false; custom_branch_policies=$true }
            protection_rules=@(@{ type='required_reviewers'; reviewers=@(@{ type='User'; reviewer=@{ id=42 } }); prevent_self_review=$true })
            can_admins_bypass=$false
        })
        '/repos/example/app/environments/app-dev/deployment-branch-policies'=(New-ApiSuccess @{ branch_policies=@(@{ name='master'; type='branch' }); total_count=1 })
        '/repos/example/app/environments/app-dev/variables'=(New-ApiSuccess @{ variables=@(); total_count=0 })
        '/orgs/example/actions/runner-groups'=(New-ApiSuccess @{ runner_groups=@(@{ id=7; name='app-deployment' }); total_count=1 })
        '/orgs/example/actions/runner-groups/7'=(New-ApiSuccess @{
            id=7; name='app-deployment'; visibility='selected'; allows_public_repositories=$false
            inherited=$true;restricted_to_workflows=$true; selected_workflows=@(('clcdpc/clc-deployment/.github/workflows/application-deploy.yml@'+('a'*40)),'example/app/.github/workflows/diagnose.yml@refs/heads/master')
        })
        '/orgs/example/actions/runner-groups/7/repositories'=(New-ApiSuccess @{ repositories=@(@{ full_name='example/app' }); total_count=1 })
        '/orgs/example/actions/runner-groups/7/runners'=(New-ApiSuccess @{
            runners=@(@{ status='online'; labels=@(@{ name='self-hosted' },@{ name='Windows' },@{ name='X64' }) }); total_count=1
        })
    }
    $protected=@{contractVersion=1;applicationId='app';repository='example/app';integrationBranch='master';
        sourcePolicy=@{allowSnapshots=$true;allowUnmergedDevTags=$true;allowTestTags=$false};
        producer=@{workflowPath='.github/workflows/release.yml';job='build'};
        trustedFiles=@('.clc/release.json','.github/workflows/release.yml','.github/workflows/deploy-release.yml');requiredToolkitContractVersion=2;
        orchestration=@{sharedRevision=('a'*40);deploymentWorkflowPath='.github/workflows/deploy-release.yml'};
        targets=@(@{channel='DEV';targetId='app-dev';standingAuthorizationId='app-dev';environment='app-dev';runnerGroup='app-deployment';runnerLabels=@('self-hosted','Windows','X64');enabled=$false;runnerAdmissionReady=$false})}
    $fixture[('/repos/example/app/contents/.clc/release.json?ref='+('b'*40))]=New-WorkflowFile ($protected | ConvertTo-Json -Depth 12)
    $shared=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../.github/workflows/application-deploy.yml') -Raw
    $fixture[('/repos/clcdpc/clc-deployment/contents/.github/workflows/application-deploy.yml?ref='+('a'*40))]=New-WorkflowFile $shared
    return $fixture
}

function Get-FixtureProtectedConfiguration($Fixture) {
    $entry=$Fixture[('/repos/example/app/contents/.clc/release.json?ref='+('b'*40))].data
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.content)) | ConvertFrom-Json -AsHashtable
}
function Set-FixtureProtectedConfiguration($Fixture,$Record) {
    $Fixture[('/repos/example/app/contents/.clc/release.json?ref='+('b'*40))]=New-WorkflowFile ($Record | ConvertTo-Json -Depth 12)
}
function New-PassingStageChecks([string] $Category) {
    $definitions=& (Get-Module Validation) {Get-ClcDeploymentPrerequisiteDefinitions}
    foreach ($id in @($definitions.Keys | Sort-Object -CaseSensitive)) {
        if ($id.StartsWith($Category+'.') -and $definitions[$id] -and $id -cnotin @('host.stage','github.stage','host.report.subject','github.inspection')) {
            New-ClcDeploymentPrerequisiteCheck $id PASS 'Synthetic trusted observation.'
        }
    }
}
