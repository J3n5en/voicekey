param(
    [Parameter(Mandatory = $true)]
    [string]$KotlinLib
)

$ErrorActionPreference = 'Stop'
# 编译真实 Session、Prefs 与时机模型及隔离桩，执行确定性状态/时钟测试；不依赖 Android SDK，也不代表设备集成测试。
#
# Compile the real Session, Prefs, and timing model with isolated fakes and run deterministic state/clock tests.
# This needs no Android SDK and does not constitute device integration testing.
$compilerLib = (Resolve-Path $KotlinLib).Path
$stdlib = Get-ChildItem -LiteralPath $compilerLib -Filter 'kotlin-stdlib.jar' | Select-Object -First 1
if (-not $stdlib) {
    $stdlib = Get-ChildItem -LiteralPath $compilerLib -Filter 'kotlin-stdlib-*.jar' |
        Where-Object { $_.Name -match '^kotlin-stdlib-\d[^/]*\.jar$' -and $_.Name -notmatch '-(sources|javadoc)\.jar$' } |
        Select-Object -First 1
}
if (-not $stdlib) { throw 'Kotlin standard library not found' }
$productionSources = @('Session.kt', 'Prefs.kt', 'JevSelectionTiming.kt') | ForEach-Object {
    (Resolve-Path "$PSScriptRoot/../../main/java/j3/voicekey/$_").Path
}
$testSources = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.kt' | ForEach-Object { $_.FullName })
$testTemp = Join-Path ([IO.Path]::GetTempPath()) ("voicekey-session-" + [guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $testTemp)
try {
    $classes = Join-Path $testTemp 'classes'
    & java -cp "$compilerLib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -classpath $stdlib.FullName -d $classes @productionSources @testSources
    if ($LASTEXITCODE -ne 0) { throw "Kotlin compilation failed: $LASTEXITCODE" }
    $runtimeClasspath = $classes + [IO.Path]::PathSeparator + $stdlib.FullName
    & java -cp $runtimeClasspath j3.voicekey.SessionHarnessKt
    if ($LASTEXITCODE -ne 0) { throw "Session tests failed: $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $testTemp -Recurse -Force
}
