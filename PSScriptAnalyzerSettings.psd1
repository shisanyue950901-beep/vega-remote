# PSScriptAnalyzer 配置
# CI 只关心 Error / Warning；控制台输出是本项目脚本的交互方式，豁免 PSAvoidUsingWriteHost。
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
    )
}
