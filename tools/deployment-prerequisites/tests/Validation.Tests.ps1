BeforeDiscovery {Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force}

Describe 'Bounded GitHub GET transport without network access' {
    BeforeAll {
        Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class ClcDeploymentPrerequisiteFixtureHandler : HttpMessageHandler {
    public string Body = "[]";
    public HttpStatusCode Code = HttpStatusCode.OK;
    public bool ThrowTransport = false;
    public string LastMethod;
    public string LastUri;
    public int Count;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
        Count++;
        LastMethod = request.Method.Method;
        LastUri = request.RequestUri.AbsoluteUri;
        if (ThrowTransport) throw new HttpRequestException("PRIVATE-DO-NOT-LOG");
        return Task.FromResult(new HttpResponseMessage(Code) { Content = new StringContent(Body) });
    }
}
'@
    }
    InModuleScope Validation {
        BeforeEach {
            $context=@{requests=0;timer=[Diagnostics.Stopwatch]::StartNew()}

            $script:fake=[ClcDeploymentPrerequisiteFixtureHandler]::new()
            $context.client=[Net.Http.HttpClient]::new($script:fake)
            $context.client.MaxResponseContentBufferSize=1024
        }
        AfterEach { $context.client.Dispose(); $context.timer.Stop() }

        It 'uses GET and the fixed GitHub API origin and preserves array JSON shapes' {
            $script:fake.Body='[{"id":1}]'
            $result=Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app/rulesets'
            $result.ok | Should -BeTrue
            ($result.data -is [array]) | Should -BeTrue
            $result.data.Count | Should -Be 1
            $script:fake.LastMethod | Should -Be GET
            $script:fake.LastUri | Should -Be 'https://api.github.com/repos/example/app/rulesets'
            $script:fake.Body='[]'
            (Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app/rulesets').data.Count | Should -Be 0
        }

        It 'suppresses raw response bodies on errors' -ForEach @(401,403,404,429,500,503,302) {
            $script:fake.Code=[Net.HttpStatusCode]$_
            $script:fake.Body='PRIVATE-DO-NOT-LOG'
            $result=Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app/rulesets'
            $result.ok | Should -BeFalse
            $result.code | Should -Be $_
            ($result | ConvertTo-Json) | Should -Not -Match 'PRIVATE-DO-NOT-LOG'
            $script:fake.Count | Should -Be 1
        }

        It 'classifies transport, JSON and response bounds without exposing private exceptions' {
            $script:fake.ThrowTransport=$true
            $result=Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app/rulesets'
            $result.ok | Should -BeFalse
            $result.code | Should -Be 0
            ($result | ConvertTo-Json) | Should -Not -Match 'PRIVATE-DO-NOT-LOG'
            $script:fake.ThrowTransport=$false
            $script:fake.Body='invalid-json'
            (Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app/rulesets').ok | Should -BeFalse
            $script:fake.Body=' ' * 2048
            (Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app/rulesets').ok | Should -BeFalse
        }

        It 'rejects arbitrary endpoints before sending a request' {
            { Get-ClcDeploymentPrerequisiteApi $context 'https://attacker.invalid/collect' } | Should -Throw
            { Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app?x=bad#fragment' } | Should -Throw
            $script:fake.Count | Should -Be 0
        }

        It 'stops when the request or overall time budget is exhausted' {
            $context.requests=150
            (Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app/rulesets').ok | Should -BeFalse
            $script:fake.Count | Should -Be 0
            $context.requests=0
            $context.timer=[pscustomobject]@{ Elapsed=[pscustomobject]@{ TotalSeconds=241 } }
            $context.timer | Add-Member -MemberType ScriptMethod -Name Stop -Value {}
            (Get-ClcDeploymentPrerequisiteApi $context '/repos/example/app/rulesets').ok | Should -BeFalse
            $script:fake.Count | Should -Be 0
        }
    }
}

Describe 'Reusable workflow trust boundary and syntax' {
    BeforeAll {
        $root=Join-Path $PSScriptRoot '../../..'
        $workflowPath=Join-Path $root '.github/workflows/validate-deployment.yml'
        $workflowText=Get-Content -LiteralPath $workflowPath -Raw
        Add-Type -LiteralPath $env:CLC_PREREQUISITES_YAML
        function Read-TestWorkflowSyntax([string] $Text) {
            # Syntax validation permits GitHub's anchors without interpreting
            # them as deployment-admission evidence. Bound the event stream
            # before loading data-only representation nodes; no object serializer.
            if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt 262144) { throw 'Workflow syntax size bound' }
            $reader=[IO.StringReader]::new($Text)
            try {
                $parser=[YamlDotNet.Core.Parser]::new($reader)
                $events=0; $depth=0
                while ($parser.MoveNext()) {
                    if (++$events -gt 40000) { throw 'Workflow syntax event bound' }
                    $kind=$parser.Current.GetType().Name
                    if ($kind -cin @('MappingStart','SequenceStart') -and ++$depth -gt 32) { throw 'Workflow syntax depth bound' }
                    if ($kind -cin @('MappingEnd','SequenceEnd')) { $depth-- }
                }
            } finally { $reader.Dispose() }
            $stream=[YamlDotNet.RepresentationModel.YamlStream]::new()
            $reader=[IO.StringReader]::new($Text)
            try { $stream.Load($reader) } finally { $reader.Dispose() }
            if ($stream.Documents.Count -ne 1) { throw 'One workflow document required' }
            return ,$stream.Documents[0].RootNode
        }
    }
    It 'validates all repository workflow syntax using bounded representation nodes' {
        foreach ($path in Get-ChildItem -LiteralPath (Join-Path $root '.github/workflows') -File) {
            $yaml=Read-TestWorkflowSyntax (Get-Content -LiteralPath $path.FullName -Raw)
            $yaml.NodeType.ToString() | Should -BeExactly Mapping
            $yaml.Children.ContainsKey([YamlDotNet.RepresentationModel.YamlScalarNode]::new('on')) | Should -BeTrue
            $jobs=$yaml.Children[[YamlDotNet.RepresentationModel.YamlScalarNode]::new('jobs')]
            $jobs.NodeType.ToString() | Should -BeExactly Mapping
            $jobs.Children.Count | Should -BeGreaterThan 0
        }
    }
    It 'accepts anchored workflow syntax without expanding it into diagnostic policy objects' {
        $yaml=Read-TestWorkflowSyntax "on: workflow_call`njobs: {one: &job {runs-on: windows-2022}, two: *job}"
        $yaml.NodeType.ToString() | Should -BeExactly Mapping
    }
    It 'rejects malformed or excessive syntax input: <Kind>' -ForEach @(
        @{Kind='malformed';Text='jobs: [unterminated'},
        @{Kind='size';Text=('x'*262145)},
        @{Kind='depth';Text=(('['*40)+'x'+(']'*40))}
    ) {
        { Read-TestWorkflowSyntax $Text } | Should -Throw
    }
    It 'parses owned diagnostic YAML using the stricter bounded observation parser' {
        InModuleScope Validation -Parameters @{ Root=$root; Assembly=$env:CLC_PREREQUISITES_YAML } {
            Add-Type -LiteralPath $Assembly
            foreach ($relative in @('.github/workflows/validate-deployment.yml','.github/workflows/test-deployment-prerequisites.yml','docs/examples/deployment-readiness.yml')) {
                $yaml=ConvertFrom-ClcDeploymentPrerequisiteYaml (Get-Content -LiteralPath (Join-Path $Root $relative) -Raw)
                $yaml['jobs'].Count | Should -BeGreaterThan 0
                $yaml.Contains('on') | Should -BeTrue
            }
        }
    }
    It 'checks out the exact shared implementation and has no caller checkout or privileged runner' {
        $workflowText | Should -Match 'repository: clcdpc/clc-deployment'
        $workflowText | Should -Match "workflow_repository.*-cne 'clcdpc/clc-deployment'"
        $workflowText | Should -Match 'workflow_sha'
        $workflowText | Should -Match 'ref: \$\{\{ steps.source.outputs.sha \}\}'
        $workflowText | Should -Match 'persist-credentials: false'
        $workflowText | Should -Not -Match 'pull_request_target|id-token: write|contents: write|actions: write|secrets: inherit|runs-on: self-hosted'
        $workflowText | Should -Not -Match '(?m)^\s+environment: \$\{\{ inputs.environment_name'
    }
    It 'passes optional empty group and explicit labels unchanged through both hosted paths' {
        InModuleScope Validation -Parameters @{Text=$workflowText} {
            $workflow=ConvertFrom-ClcDeploymentPrerequisiteYaml $Text
            $input=$workflow['on']['workflow_call']['inputs']['runner_group']
            $input['type'] | Should -Be string;$input['default'] | Should -BeExactly ''
            $input['required'] | Should -Not -Be 'true'
            foreach ($job in @('validate','administrative')) {
                $step=$workflow['jobs'][$job]['steps'] | Where-Object {$_['id'] -ceq 'validate'}
                $step['env']['CLC_RUNNER_GROUP'] | Should -BeExactly '${{ inputs.runner_group }}'
                $step['env']['CLC_RUNNER_LABELS'] | Should -BeExactly '${{ inputs.runner_labels }}'
                $step['run'] | Should -Match '-RunnerGroup \$env:CLC_RUNNER_GROUP -RunnerLabels \$env:CLC_RUNNER_LABELS'
            }
        }
    }
    It 'runs reusable hosted smoke coverage for explicit and empty group configuration' {
        InModuleScope Validation -Parameters @{Root=$root} {
            $workflow=ConvertFrom-ClcDeploymentPrerequisiteYaml (Get-Content -LiteralPath (Join-Path $Root '.github/workflows/test-deployment-prerequisites.yml') -Raw)
            foreach ($job in @('workflow-smoke','workflow-smoke-empty')) {
                $workflow['jobs'][$job]['uses'] | Should -BeExactly './.github/workflows/validate-deployment.yml'
            }
            $workflow['jobs']['workflow-smoke']['with']['runner_group'] | Should -BeExactly 'validator-smoke-not-configured'
            $workflow['jobs']['workflow-smoke-empty']['with']['runner_group'] | Should -BeExactly ''
            $workflow['jobs']['workflow-smoke-empty']['with']['runner_labels'] | Should -BeExactly ''
        }
    }
}
