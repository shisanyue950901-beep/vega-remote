#Requires -Version 5.1
<#
  Select-VegaAdapter / 编码器映射的单元测试（Pester 5）。
  纯函数，不访问系统，不需要 Windows。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
}

Describe 'Select-VegaAdapter' {
    It 'NVIDIA 优先于 AMD 与 Intel' {
        $gpus = @(
            'Intel(R) UHD Graphics 770',
            'AMD Radeon RX 6800',
            'NVIDIA GeForce RTX 4070'
        )
        Select-VegaAdapter -GpuNames $gpus | Should -Be 'NVIDIA GeForce RTX 4070'
    }

    It '没有 NVIDIA 时选 AMD 独显，而不是 Intel' {
        $gpus = @(
            'Intel(R) UHD Graphics',
            'AMD Radeon RX 6700 XT'
        )
        Select-VegaAdapter -GpuNames $gpus | Should -Be 'AMD Radeon RX 6700 XT'
    }

    It 'Radeon Pro 也算 AMD 独显' {
        $gpus = @('Intel(R) UHD Graphics 630', 'AMD Radeon Pro W6800')
        Select-VegaAdapter -GpuNames $gpus | Should -Be 'AMD Radeon Pro W6800'
    }

    It 'Radeon VII 也算 AMD 独显' {
        $gpus = @('Intel(R) HD Graphics 530', 'AMD Radeon VII')
        Select-VegaAdapter -GpuNames $gpus | Should -Be 'AMD Radeon VII'
    }

    It 'AMD 集显不参与第二优先级，退到 Intel' {
        $gpus = @(
            'Intel(R) Iris(R) Xe Graphics',
            'AMD Radeon(TM) Graphics'
        )
        Select-VegaAdapter -GpuNames $gpus | Should -Be 'Intel(R) Iris(R) Xe Graphics'
    }

    It 'AMD 集显（780M）不被误判为独显' {
        $gpus = @('AMD Radeon 780M', 'Intel(R) UHD Graphics')
        Select-VegaAdapter -GpuNames $gpus | Should -Be 'AMD Radeon 780M'
        # 第一个就是它：没有别的候选时直接取第一个，不是因为它被识别成独显
        Select-VegaAdapter -GpuNames @('AMD Radeon 780M', 'Intel(R) UHD Graphics') -SkipVirtual |
            Should -Be 'AMD Radeon 780M'
    }

    It '什么都不匹配时取第一个' {
        $gpus = @('Microsoft Basic Display Adapter', 'Intel(R) UHD Graphics')
        Select-VegaAdapter -GpuNames $gpus | Should -Be 'Microsoft Basic Display Adapter'
    }

    It '-SkipVirtual 跳过虚拟适配器' {
        $gpus = @('Microsoft Basic Display Adapter', 'Intel(R) UHD Graphics 630')
        Select-VegaAdapter -GpuNames $gpus -SkipVirtual | Should -Be 'Intel(R) UHD Graphics 630'
    }

    It '全是虚拟适配器时 -SkipVirtual 返回 $null' {
        $gpus = @('Microsoft Basic Display Adapter', 'Parsec Virtual Display')
        Select-VegaAdapter -GpuNames $gpus -SkipVirtual | Should -BeNullOrEmpty
    }

    It '空输入返回 $null' {
        Select-VegaAdapter -GpuNames @() | Should -BeNullOrEmpty
        Select-VegaAdapter -GpuNames $null | Should -BeNullOrEmpty
        Select-VegaAdapter -GpuNames @('', '   ') | Should -BeNullOrEmpty
    }

    It '去掉首尾空白' {
        Select-VegaAdapter -GpuNames @('  NVIDIA GeForce RTX 3060  ') | Should -Be 'NVIDIA GeForce RTX 3060'
    }

    It '同品牌多张卡取第一张' {
        $gpus = @('NVIDIA GeForce RTX 4090', 'NVIDIA GeForce RTX 3060')
        Select-VegaAdapter -GpuNames $gpus | Should -Be 'NVIDIA GeForce RTX 4090'
    }
}

Describe 'Get-VegaEncoderName' {
    It 'NVIDIA 映射到 NVENC' {
        Get-VegaEncoderName -AdapterName 'NVIDIA GeForce RTX 4070' | Should -Be 'NVENC'
    }

    It 'AMD 映射到 AMF' {
        Get-VegaEncoderName -AdapterName 'AMD Radeon RX 6800' | Should -Be 'AMF'
    }

    It 'Intel 映射到 QSV' {
        Get-VegaEncoderName -AdapterName 'Intel(R) UHD Graphics 770' | Should -Be 'QSV'
    }

    It '未知显卡与空值回退到 SOFTWARE' {
        Get-VegaEncoderName -AdapterName 'Some Unknown GPU' | Should -Be 'SOFTWARE'
        Get-VegaEncoderName -AdapterName '' | Should -Be 'SOFTWARE'
        Get-VegaEncoderName -AdapterName $null | Should -Be 'SOFTWARE'
    }
}
