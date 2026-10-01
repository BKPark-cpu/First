#requires -Version 5.1
<#
.SYNOPSIS
  수주·매출 실적 검증 → 월 마감 → 경영실적 보고서 생성

.DESCRIPTION
  input 폴더의 수주실적·매출실적·손익실적·제품군매핑·사업계획 CSV를 읽어
  (1) 검증 결과, (2) 경영실적 보고서(HTML·MD), (3) 집계 CSV를 만든다.
  -Close 를 주면 검증 오류가 0건일 때만 대상월을 마감(스냅샷 고정 + 마감이력 기록)한다.
  -Reopen 은 가장 최근 마감월만 사유와 함께 다시 연다.
  원본 CSV는 수정하지 않는다.

.EXAMPLE
  .\Invoke-PerformanceReport.ps1 -InputDir ..\input -Month 2026-02
  .\Invoke-PerformanceReport.ps1 -InputDir ..\input -Month 2026-02 -Close
  .\Invoke-PerformanceReport.ps1 -InputDir ..\input -Month 2026-02 -Reopen -Reason "2월 매출 1건 누락"
  .\Invoke-PerformanceReport.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$InputDir,
    [string]$OutDir,
    [string]$Month,
    [switch]$Close,
    [switch]$Reopen,
    [string]$Reason = '',
    [string]$Operator = $env:USERNAME,
    [string]$Now,
    [string]$OrdersCsv,
    [string]$SalesCsv,
    [string]$MappingCsv,
    [string]$PlanCsv,
    [string]$PnlCsv,
    [string]$HistoryCsv,
    [string]$ClosedDir,
    [string]$ConfigPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskRoot = Split-Path -Parent $ScriptRoot
Add-Type -AssemblyName Microsoft.VisualBasic
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ─────────────────────────────────────────────────────────────
# 1. 설정
# ─────────────────────────────────────────────────────────────
if (-not $ConfigPath) { $ConfigPath = Join-Path $TaskRoot 'config.json' }
$Cfg = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$FyStart = [int]$Cfg.fiscalYearStartMonth
$Unit = [decimal]$Cfg.reportUnit
$UnitLabel = [string]$Cfg.reportUnitLabel
$PlanUnit = [decimal]$Cfg.planUnit
$MaintType = [string]$Cfg.maintenanceType
$MaintAsGroup = [bool]$Cfg.maintenanceAsGroup
$MappingBasis = [string]$Cfg.mappingBasis

$TypeMap = @{}
foreach ($p in $Cfg.typeValues.PSObject.Properties) {
    foreach ($v in $p.Value) { $TypeMap[($v -replace '\s', '').ToUpperInvariant()] = $p.Name }
}

# ─────────────────────────────────────────────────────────────
# 2. 공통 함수 (파싱·월 계산)
# ─────────────────────────────────────────────────────────────
function Get-NormKey([string]$s) { if ($null -eq $s) { return '' } return ($s -replace '\s', '').ToUpperInvariant() }

function ConvertTo-Amount([string]$s) {
    # 반환: @{ Ok; Blank; Value }
    if ($null -eq $s) { return @{ Ok = $true; Blank = $true; Value = [decimal]0 } }
    $t = $s.Trim() -replace '[,\s₩]', ''
    $t = $t -replace '원$', ''
    if ($t -eq '') { return @{ Ok = $true; Blank = $true; Value = [decimal]0 } }
    if ($t -eq '-') { return @{ Ok = $true; Blank = $false; Value = [decimal]0 } }
    $neg = $false
    if ($t -match '^\((.*)\)$') { $neg = $true; $t = $Matches[1] }
    $d = [decimal]0
    if (-not [decimal]::TryParse($t, [Globalization.NumberStyles]::Number, $Inv, [ref]$d)) {
        return @{ Ok = $false; Blank = $false; Value = [decimal]0 }
    }
    if ($neg) { $d = - $d }
    return @{ Ok = $true; Blank = $false; Value = $d }
}

function ConvertTo-Month([string]$s) {
    # 'yyyy-MM' 또는 $null. 숫자만 있는 값(엑셀 일련번호 등)은 날짜로 보지 않는다.
    if ($null -eq $s) { return $null }
    $t = $s.Trim()
    if ($t -eq '') { return $null }
    $t = $t -replace '\s+\d{1,2}:\d{2}(:\d{2})?$', ''
    $y = 0; $m = 0; $d = 0
    $r = [regex]::Match($t, '^(\d{4})\s*(?:[-./]|년)\s*(\d{1,2})\s*(?:(?:[-./]|월)\s*(?:(\d{1,2})\s*(?:\.|일)?)?)?$')
    if ($r.Success) {
        $y = [int]$r.Groups[1].Value; $m = [int]$r.Groups[2].Value
        if ($r.Groups[3].Success) { $d = [int]$r.Groups[3].Value }
    }
    else {
        $r = [regex]::Match($t, '^(\d{4})(\d{2})(\d{2})$')
        if (-not $r.Success) { return $null }
        $y = [int]$r.Groups[1].Value; $m = [int]$r.Groups[2].Value; $d = [int]$r.Groups[3].Value
    }
    if ($y -lt 1990 -or $y -gt 2100 -or $m -lt 1 -or $m -gt 12) { return $null }
    if ($d -ne 0 -and ($d -lt 1 -or $d -gt [DateTime]::DaysInMonth($y, $m))) { return $null }
    return ('{0:0000}-{1:00}' -f $y, $m)
}

function Get-MKey([string]$m) { return ([int]$m.Substring(0, 4)) * 12 + ([int]$m.Substring(5, 2)) - 1 }
function Get-MStr([int]$k) { return ('{0:0000}-{1:00}' -f [math]::Floor($k / 12), ($k % 12 + 1)) }
function Get-FY([string]$m) {
    $y = [int]$m.Substring(0, 4); $mm = [int]$m.Substring(5, 2)
    if ($FyStart -eq 1) { return $y }
    if ($mm -ge $FyStart) { return $y + 1 } else { return $y }
}
function Get-FYIndex([string]$m) { $mm = [int]$m.Substring(5, 2); return (($mm - $FyStart + 12) % 12) + 1 }

function Format-Dec([decimal]$d) { return $d.ToString('0.##########', $Inv) }

function Get-Hash([string[]]$lines) {
    $arr = [string[]]@($lines)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($arr -join "`n")))
    return (-join ($bytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
}

function Round-Unit($v) {
    if ($null -eq $v) { return $null }
    return [math]::Round([decimal]$v / $Unit, 0, [MidpointRounding]::AwayFromZero)
}

function Format-Num($v) {
    # 보고 단위 금액. 음수는 (1,234)
    if ($null -eq $v) { return '-' }
    $r = Round-Unit $v
    if ($r -lt 0) { return '(' + (- $r).ToString('#,0', $Inv) + ')' }
    return $r.ToString('#,0', $Inv)
}

function Format-Diff($cur, $base) {
    if ($null -eq $cur -or $null -eq $base) { return '-' }
    $r = Round-Unit ([decimal]$cur - [decimal]$base)
    if ($r -gt 0) { return '▲' + $r.ToString('#,0', $Inv) }
    if ($r -lt 0) { return '▼' + (- $r).ToString('#,0', $Inv) }
    return '0'
}

function Get-Rate($cur, $base) {
    # 증감률. 기준값이 0 이하이면 계산하지 않음($null)
    if ($null -eq $cur -or $null -eq $base) { return $null }
    if ([decimal]$base -le 0) { return $null }
    return ([decimal]$cur - [decimal]$base) / [decimal]$base
}

function Format-Rate($cur, $base) {
    $r = Get-Rate $cur $base
    if ($null -eq $r) { return '-' }
    $p = [math]::Round($r * 100, 0, [MidpointRounding]::AwayFromZero)
    if ($p -gt 0) { return '▲' + $p.ToString('#,0', $Inv) + '%' }
    if ($p -lt 0) { return '▼' + (- $p).ToString('#,0', $Inv) + '%' }
    return '0%'
}

function Format-Pct($v) {
    if ($null -eq $v) { return '-' }
    return ([math]::Round([decimal]$v * 100, 1, [MidpointRounding]::AwayFromZero)).ToString('0.0', $Inv) + '%'
}

function Resolve-TypeValue([string]$s) {
    $k = Get-NormKey $s
    if ($k -eq '') { return $null }
    if ($TypeMap.ContainsKey($k)) { return $TypeMap[$k] }
    return $null
}

# ─────────────────────────────────────────────────────────────
# 3. CSV 입출력
# ─────────────────────────────────────────────────────────────
function Read-TextAuto([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    try { return $Utf8Strict.GetString($bytes) }
    catch { return [Text.Encoding]::GetEncoding(949).GetString($bytes) }
}

function Import-Table([string]$Path) {
    # 반환: @{ Headers = string[]; Rows = object[] (행마다 Line, Values{정규화헤더=값}) }
    $text = (Read-TextAuto $Path).TrimStart([char]0xFEFF)
    $sr = New-Object System.IO.StringReader($text)
    $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($sr)
    $p.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $p.SetDelimiters(',')
    $p.HasFieldsEnclosedInQuotes = $true
    $p.TrimWhiteSpace = $false
    $headers = @()
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        while (-not $p.EndOfData) {
            $line = $p.LineNumber
            $f = $p.ReadFields()
            if ($null -eq $f) { continue }
            if ($headers.Count -eq 0) { $headers = @($f | ForEach-Object { $_.Trim() }); continue }
            $vals = @{}
            $allBlank = $true
            for ($i = 0; $i -lt $headers.Count; $i++) {
                $v = if ($i -lt $f.Length) { $f[$i].Trim() } else { '' }
                $k = Get-NormKey $headers[$i]
                if ($k -ne '' -and -not $vals.ContainsKey($k)) { $vals[$k] = $v }
                if ($v -ne '') { $allBlank = $false }
            }
            if (-not $allBlank) { $rows.Add(@{ Line = $line; Values = $vals }) }
        }
    }
    catch [Microsoft.VisualBasic.FileIO.MalformedLineException] {
        throw ("{0}: {1}행의 따옴표가 닫히지 않았습니다." -f $Path, $p.ErrorLineNumber)
    }
    finally { $p.Close() }
    return @{ Headers = $headers; Rows = $rows.ToArray() }
}

function Resolve-Columns($Table, $Spec, [string[]]$Required, [string]$FileLabel) {
    # 반환: @{ 논리명 = 정규화헤더 또는 $null }
    $norm = @{}
    foreach ($h in $Table.Headers) { $norm[(Get-NormKey $h)] = $h }
    $map = @{}
    foreach ($p in $Spec.PSObject.Properties) {
        $found = $null
        foreach ($cand in $p.Value) { $k = Get-NormKey $cand; if ($norm.ContainsKey($k)) { $found = $k; break } }
        $map[$p.Name] = $found
        if ($null -eq $found -and $Required -contains $p.Name) {
            throw ("[{0}] '{1}' 열을 찾지 못했습니다. 인식하는 이름: {2} / 실제 헤더: {3}" -f $FileLabel, $p.Name, ($p.Value -join ', '), ($Table.Headers -join ', '))
        }
    }
    return $map
}

function Get-Val($Row, $Map, [string]$Name) {
    $k = $Map[$Name]
    if ($null -eq $k) { return '' }
    if ($Row.Values.ContainsKey($k)) { return $Row.Values[$k] }
    return ''
}

function ConvertTo-CsvField([string]$s) {
    if ($null -eq $s) { return '' }
    if ($s -match '[",\r\n]') { return '"' + ($s -replace '"', '""') + '"' }
    return $s
}

function Write-Csv([string]$Path, [string[]]$Headers, $Rows) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine((($Headers | ForEach-Object { ConvertTo-CsvField $_ }) -join ','))
    foreach ($r in $Rows) { [void]$sb.AppendLine((($r | ForEach-Object { ConvertTo-CsvField ([string]$_) }) -join ',')) }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $sb.ToString(), $Utf8Bom)
}

function Write-Text([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $Utf8Bom)
}

# ─────────────────────────────────────────────────────────────
# 4. 원장 읽기 (수주·매출·손익) + 행 단위 검증
# ─────────────────────────────────────────────────────────────
$Issues = New-Object System.Collections.Generic.List[object]
function Add-Issue([string]$Level, [string]$Code, [string]$File, $Line, [string]$Pjt, [string]$Mon, [string]$Msg) {
    $Issues.Add([pscustomobject]@{ Level = $Level; Code = $Code; File = $File; Line = $Line; Pjt = $Pjt; Month = $Mon; Message = $Msg })
}

function New-LedgerRow([string]$Kind, [string]$Mon, [string]$Pjt, [string]$Name, [string]$Cust, [string]$Grp, [string]$Typ, [string]$Dept, [string]$Owner, [decimal]$Gross, [decimal]$C1, [decimal]$C2, [string]$Ref, $Line, [string]$Src) {
    return [pscustomobject]@{
        Kind = $Kind; Month = $Mon; Pjt = $Pjt; PjtName = $Name; Customer = $Cust; RawGroup = $Grp; Type = $Typ
        Dept = $Dept; Owner = $Owner; Gross = $Gross; Cost1 = $C1; Cost2 = $C2; Net = ($Gross - $C1 - $C2); Ref = $Ref
        Line = $Line; Src = $Src
    }
}

function Get-Canon($r) {
    return ($r.Kind, $r.Month, $r.Pjt, $r.PjtName, $r.Customer, $r.RawGroup, $r.Type, $r.Dept, $r.Owner, (Format-Dec $r.Gross), (Format-Dec $r.Cost1), (Format-Dec $r.Cost2), $r.Ref) -join "`t"
}

function Read-Ledger([string]$Path, [string]$Kind, $Spec, [string]$FileLabel, [bool]$Quiet) {
    $t = Import-Table $Path
    $map = Resolve-Columns $t $Spec @('date', 'pjtCode', 'group', 'type', 'gross') $FileLabel
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($row in $t.Rows) {
        $rawDate = Get-Val $row $map 'date'
        $pjt = Get-Val $row $map 'pjtCode'
        $mon = ConvertTo-Month $rawDate
        $bad = $false
        if ($rawDate -eq '') { if (-not $Quiet) { Add-Issue '오류' 'E02' $FileLabel $row.Line $pjt '' '일자가 비어 있습니다' }; $bad = $true }
        elseif ($null -eq $mon) { if (-not $Quiet) { Add-Issue '오류' 'E03' $FileLabel $row.Line $pjt '' ("일자 형식을 읽을 수 없습니다: '{0}'" -f $rawDate) }; $bad = $true }
        if ($pjt -eq '') { if (-not $Quiet) { Add-Issue '오류' 'E02' $FileLabel $row.Line '' $mon 'PJT코드가 비어 있습니다' }; $bad = $true }
        $grp = Get-Val $row $map 'group'
        if ($grp -eq '') { if (-not $Quiet) { Add-Issue '오류' 'E02' $FileLabel $row.Line $pjt $mon '제품군이 비어 있습니다' }; $bad = $true }
        $typRaw = Get-Val $row $map 'type'
        $typ = Resolve-TypeValue $typRaw
        if ($null -eq $typ) {
            if (-not $Quiet) {
                if ($typRaw -eq '') { Add-Issue '오류' 'E02' $FileLabel $row.Line $pjt $mon '구분(구축/유지보수)이 비어 있습니다' }
                else { Add-Issue '오류' 'E05' $FileLabel $row.Line $pjt $mon ("구분 값을 알 수 없습니다: '{0}' (config.json typeValues 확인)" -f $typRaw) }
            }
            $bad = $true
        }
        $amt = @{}
        foreach ($f in @('gross', 'cost1', 'cost2')) {
            $raw = Get-Val $row $map $f
            $a = ConvertTo-Amount $raw
            if (-not $a.Ok) { if (-not $Quiet) { Add-Issue '오류' 'E03' $FileLabel $row.Line $pjt $mon ("금액 형식을 읽을 수 없습니다: {0}='{1}'" -f $f, $raw) }; $bad = $true }
            elseif ($f -eq 'gross' -and $a.Blank) { if (-not $Quiet) { Add-Issue '오류' 'E02' $FileLabel $row.Line $pjt $mon '금액이 비어 있습니다' }; $bad = $true }
            $amt[$f] = $a.Value
        }
        if ($bad) { continue }
        $r = New-LedgerRow $Kind $mon $pjt (Get-Val $row $map 'pjtName') (Get-Val $row $map 'customer') $grp $typ (Get-Val $row $map 'dept') (Get-Val $row $map 'owner') $amt['gross'] $amt['cost1'] $amt['cost2'] (Get-Val $row $map 'ref') $row.Line $FileLabel
        $c = Get-Canon $r
        if ($seen.ContainsKey($c)) {
            if (-not $Quiet) { Add-Issue '오류' 'E06' $FileLabel $row.Line $pjt $mon ("{0}행과 완전히 같은 행입니다 (실제 별건이면 계약번호/비고로 구분)" -f $seen[$c]) }
            continue
        }
        $seen[$c] = $row.Line
        $out.Add($r)
    }
    return @{ Rows = $out.ToArray(); HasDept = ($null -ne $map['dept']) }
}

function Read-Pnl([string]$Path, [string]$FileLabel, [bool]$Quiet) {
    $t = Import-Table $Path
    $map = Resolve-Columns $t $Cfg.pnlColumns @('month', 'labor', 'expense') $FileLabel
    $out = @{}
    foreach ($row in $t.Rows) {
        $raw = Get-Val $row $map 'month'
        $mon = ConvertTo-Month $raw
        if ($null -eq $mon) { if (-not $Quiet) { Add-Issue '오류' 'E03' $FileLabel $row.Line '' '' ("월 형식을 읽을 수 없습니다: '{0}'" -f $raw) }; continue }
        $vals = @{}
        $bad = $false
        foreach ($f in @('project', 'labor', 'expense', 'headcount')) {
            $rv = Get-Val $row $map $f
            $a = ConvertTo-Amount $rv
            if (-not $a.Ok) { if (-not $Quiet) { Add-Issue '오류' 'E03' $FileLabel $row.Line '' $mon ("숫자 형식을 읽을 수 없습니다: {0}='{1}'" -f $f, $rv) }; $bad = $true }
            $vals[$f] = $a.Value
            $vals[$f + 'Blank'] = $a.Blank
        }
        if ($bad) { continue }
        if ($out.ContainsKey($mon)) { if (-not $Quiet) { Add-Issue '오류' 'E06' $FileLabel $row.Line '' $mon '같은 월이 두 번 입력되었습니다' }; continue }
        $out[$mon] = [pscustomobject]@{
            Month = $mon; Project = $vals['project']; Labor = $vals['labor']; Expense = $vals['expense']
            Headcount = $vals['headcount']; HasHeadcount = (-not $vals['headcountBlank'])
        }
    }
    return $out
}

function Get-PnlCanon($p) {
    return ('P', $p.Month, (Format-Dec $p.Project), (Format-Dec $p.Labor), (Format-Dec $p.Expense), $(if ($p.HasHeadcount) { Format-Dec $p.Headcount } else { '' })) -join "`t"
}

function Read-Mapping([string]$Path) {
    $t = Import-Table $Path
    $map = Resolve-Columns $t $Cfg.mappingColumns @('raw', 'report') '제품군매핑'
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($row in $t.Rows) {
        $raw = Get-Val $row $map 'raw'; $rep = Get-Val $row $map 'report'
        if ($raw -eq '' -or $rep -eq '') { Add-Issue '오류' 'E02' '제품군매핑' $row.Line '' '' '원천제품군/보고제품군이 비어 있습니다'; continue }
        $f = Get-Val $row $map 'from'; $to = Get-Val $row $map 'to'
        $fm = $null; $tm = $null
        if ($f -ne '') { $fm = ConvertTo-Month $f; if ($null -eq $fm) { Add-Issue '오류' 'E03' '제품군매핑' $row.Line '' '' ("적용시작월 형식 오류: '{0}'" -f $f); continue } }
        if ($to -ne '') { $tm = ConvertTo-Month $to; if ($null -eq $tm) { Add-Issue '오류' 'E03' '제품군매핑' $row.Line '' '' ("적용종료월 형식 오류: '{0}'" -f $to); continue } }
        $ord = 999
        $o = Get-Val $row $map 'order'
        if ($o -ne '') { $tmp = 0; if ([int]::TryParse($o, [ref]$tmp)) { $ord = $tmp } }
        $list.Add([pscustomobject]@{ Raw = (Get-NormKey $raw); Report = $rep; From = $fm; To = $tm; Order = $ord })
    }
    return $list.ToArray()
}

function Resolve-Group($Mapping, [string]$Raw, [string]$Basis) {
    $k = Get-NormKey $Raw
    $best = $null
    foreach ($e in $Mapping) {
        if ($e.Raw -ne $k) { continue }
        if ($null -ne $e.From -and $Basis -lt $e.From) { continue }
        if ($null -ne $e.To -and $Basis -gt $e.To) { continue }
        if ($null -eq $best) { $best = $e }
        elseif ($null -ne $e.From -and ($null -eq $best.From -or $e.From -gt $best.From)) { $best = $e }
    }
    if ($null -eq $best) { return $null }
    return $best.Report
}

function Read-Plan([string]$Path) {
    $t = Import-Table $Path
    $map = Resolve-Columns $t $Cfg.planColumns @('fy', 'scope', 'target', 'metric', 'amount') '사업계획'
    $plan = @{}
    foreach ($row in $t.Rows) {
        $fy = 0
        if (-not [int]::TryParse(((Get-Val $row $map 'fy') -replace '[^0-9]', ''), [ref]$fy)) { Add-Issue '경고' 'W06' '사업계획' $row.Line '' '' '사업연도를 읽을 수 없어 건너뜁니다'; continue }
        $a = ConvertTo-Amount (Get-Val $row $map 'amount')
        if (-not $a.Ok -or $a.Blank) { Add-Issue '경고' 'W06' '사업계획' $row.Line '' '' '연간목표 금액을 읽을 수 없어 건너뜁니다'; continue }
        $key = '{0}|{1}|{2}|{3}' -f $fy, (Get-NormKey (Get-Val $row $map 'scope')), (Get-NormKey (Get-Val $row $map 'target')), (Get-NormKey (Get-Val $row $map 'metric'))
        $plan[$key] = $a.Value * $PlanUnit
    }
    return $plan
}

function Get-Plan($Plan, [int]$Fy, [string]$Scope, [string]$Target, [string]$Metric) {
    $key = '{0}|{1}|{2}|{3}' -f $Fy, (Get-NormKey $Scope), (Get-NormKey $Target), (Get-NormKey $Metric)
    if ($Plan.ContainsKey($key)) { return $Plan[$key] }
    return $null
}

# ─────────────────────────────────────────────────────────────
# 5. 마감 이력·스냅샷
# ─────────────────────────────────────────────────────────────
$HistoryHeaders = @('마감월', '상태', '버전', '일시', '실행자', '사유', '해시', '수주건수', '매출건수')

function Read-History([string]$Path) {
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $Path)) { return $list.ToArray() }
    $t = Import-Table $Path
    foreach ($row in $t.Rows) {
        $v = $row.Values
        $list.Add([pscustomobject]@{
                Month = [string]$v['마감월']; Status = [string]$v['상태']; Version = [int]$v['버전']; At = [string]$v['일시']
                Operator = [string]$v['실행자']; Reason = [string]$v['사유']; Hash = [string]$v['해시']
                Orders = [string]$v['수주건수']; Sales = [string]$v['매출건수']
            })
    }
    return $list.ToArray()
}

function Get-ClosedState($History) {
    # 반환: @{ 월 = 최신이력행 }  (상태가 '마감'인 월만)
    $latest = @{}
    foreach ($h in $History) { $latest[$h.Month] = $h }
    $closed = @{}
    foreach ($k in $latest.Keys) { if ($latest[$k].Status -eq '마감') { $closed[$k] = $latest[$k] } }
    return $closed
}

function Get-SnapshotDir([string]$Mon) { return Join-Path $ClosedRoot ($Mon -replace '-', '') }

function Write-Snapshot([string]$Dir, $Orders, $Sales, $Pnl) {
    $oh = @('수주일', 'PJT코드', 'PJT명칭', '거래처', '제품군', '구분', '부서', '담당', '수주금액', '용역비', '판매수수료', '계약번호')
    $sh = @('매출일', 'PJT코드', 'PJT명칭', '거래처', '제품군', '구분', '부서', '담당', '매출금액', '외주비', '판매수수료', '세금계산서번호')
    $toArr = { param($r) , @($r.Month, $r.Pjt, $r.PjtName, $r.Customer, $r.RawGroup, $r.Type, $r.Dept, $r.Owner, (Format-Dec $r.Gross), (Format-Dec $r.Cost1), (Format-Dec $r.Cost2), $r.Ref) }
    Write-Csv (Join-Path $Dir '수주실적.csv') $oh (@($Orders | ForEach-Object { & $toArr $_ }))
    Write-Csv (Join-Path $Dir '매출실적.csv') $sh (@($Sales | ForEach-Object { & $toArr $_ }))
    $prow = @()
    if ($null -ne $Pnl) { $prow = @(, @($Pnl.Month, (Format-Dec $Pnl.Project), (Format-Dec $Pnl.Labor), (Format-Dec $Pnl.Expense), $(if ($Pnl.HasHeadcount) { Format-Dec $Pnl.Headcount } else { '' }))) }
    Write-Csv (Join-Path $Dir '손익실적.csv') @('월', '과제기여', '인건비', '경비', '월말인원') $prow
}

function Read-Snapshot([string]$Dir) {
    $o = @(); $s = @(); $p = $null
    $f = Join-Path $Dir '수주실적.csv'; if (Test-Path $f) { $o = @((Read-Ledger $f '수주' $Cfg.orderColumns '마감스냅샷' $true).Rows) }
    $f = Join-Path $Dir '매출실적.csv'; if (Test-Path $f) { $s = @((Read-Ledger $f '매출' $Cfg.salesColumns '마감스냅샷' $true).Rows) }
    $f = Join-Path $Dir '손익실적.csv'
    if (Test-Path $f) { $pm = Read-Pnl $f '마감스냅샷' $true; foreach ($k in $pm.Keys) { $p = $pm[$k] } }
    return @{ Orders = $o; Sales = $s; Pnl = $p }
}

function Get-MonthHash($Orders, $Sales, $Pnl) {
    $lines = @($Orders | ForEach-Object { Get-Canon $_ }) + @($Sales | ForEach-Object { Get-Canon $_ })
    if ($null -ne $Pnl) { $lines += , (Get-PnlCanon $Pnl) }
    if ($lines.Count -eq 0) { return 'EMPTY' }
    return Get-Hash $lines
}

# ─────────────────────────────────────────────────────────────
# 6. 자체 테스트
# ─────────────────────────────────────────────────────────────
function Invoke-SelfTest {
    $results = New-Object System.Collections.Generic.List[object]
    $t = {
        param($id, $name, $actual, $expected)
        $ok = ([string]$actual -ceq [string]$expected)
        $results.Add([pscustomobject]@{ Id = $id; Name = $name; Ok = $ok; Actual = $actual; Expected = $expected })
    }
    $mapping = @(
        [pscustomobject]@{ Raw = (Get-NormKey '전자문서'); Report = '전자문서'; From = $null; To = '2025-12'; Order = 5 },
        [pscustomobject]@{ Raw = (Get-NormKey '전자문서'); Report = '위변조방지'; From = '2026-01'; To = $null; Order = 5 },
        [pscustomobject]@{ Raw = (Get-NormKey 'DRM'); Report = 'DRM'; From = $null; To = $null; Order = 1 }
    )
    & $t 'UT-01' '금액: 쉼표' (ConvertTo-Amount '30,000,000').Value 30000000
    & $t 'UT-02' '금액: 원 표기' (ConvertTo-Amount '30,000,000원').Value 30000000
    & $t 'UT-03' '금액: 괄호 음수' (ConvertTo-Amount '(1,000)').Value -1000
    & $t 'UT-04' '금액: 빈칸 = Blank' (ConvertTo-Amount '').Blank $true
    & $t 'UT-05' '금액: 문자 오입력' (ConvertTo-Amount '삼천').Ok $false
    & $t 'UT-06' '일자: yyyy-MM-dd' (ConvertTo-Month '2026-02-15') '2026-02'
    & $t 'UT-07' '일자: 2026. 2. 15.' (ConvertTo-Month '2026. 2. 15.') '2026-02'
    & $t 'UT-08' '일자: 2026년 2월' (ConvertTo-Month '2026년 2월') '2026-02'
    & $t 'UT-09' '일자: 숫자만(45000)은 날짜 아님' ([string](ConvertTo-Month '45000')) ''
    & $t 'UT-10' '일자: 존재하지 않는 날(2026-02-30)' ([string](ConvertTo-Month '2026-02-30')) ''
    & $t 'UT-11' '사업연도: 2025-10 → FY2026, 1번째 달' ('{0}/{1}' -f (Get-FY '2025-10'), (Get-FYIndex '2025-10')) '2026/1'
    & $t 'UT-12' '사업연도: 2026-09 → FY2026, 12번째 달' ('{0}/{1}' -f (Get-FY '2026-09'), (Get-FYIndex '2026-09')) '2026/12'
    & $t 'UT-13' '매핑: 2025-11 기준 전자문서 → 전자문서' (Resolve-Group $mapping '전자문서' '2025-11') '전자문서'
    & $t 'UT-14' '매핑: 2026-02 기준 전자문서 → 위변조방지' (Resolve-Group $mapping '전자 문서' '2026-02') '위변조방지'
    & $t 'UT-15' '매핑: 없는 제품군 → null' ([string](Resolve-Group $mapping 'XYZ' '2026-02')) ''
    $r = New-LedgerRow '수주' '2026-02' 'P1' '' '' 'DRM' '구축' '' '' 100000000 15000000 5000000 '' 2 'x'
    & $t 'UT-16' '순수주 = 수주금액 − 용역비 − 판매수수료' $r.Net 80000000
    & $t 'UT-17' '구분: 유지관리 → 유지보수' (Resolve-TypeValue '유지 관리') '유지보수'
    & $t 'UT-18' '반올림: 1,500,000원 → 2백만원' (Round-Unit 1500000) 2
    & $t 'UT-19' '반올림: -1,500,000원 → -2백만원' (Round-Unit -1500000) -2
    & $t 'UT-20' '증감률: 기준 0이면 계산 안 함' (Format-Rate 100 0) '-'
    & $t 'UT-21' '증감률: 150 vs 100 → ▲50%' (Format-Rate 150 100) '▲50%'
    & $t 'UT-22' '표시: 음수는 괄호' (Format-Num -250000000) '(250)'
    & $t 'UT-23' '해시: 행 순서와 무관' ((Get-Hash @('a', 'b', 'c')) -eq (Get-Hash @('c', 'a', 'b'))) $true
    $r2 = New-LedgerRow '수주' '2026-02' 'P1' '' '' 'DRM' '구축' '' '' 100000000 15000000 5000001 '' 3 'x'
    & $t 'UT-24' '해시: 금액 1원 차이 감지' ((Get-MonthHash @($r) @() $null) -ne (Get-MonthHash @($r2) @() $null)) $true

    $pass = 0
    foreach ($x in $results) {
        if ($x.Ok) { $pass++; Write-Host ('PASS {0} {1}' -f $x.Id, $x.Name) }
        else { Write-Host ('FAIL {0} {1} — 실제 [{2}] / 기대 [{3}]' -f $x.Id, $x.Name, $x.Actual, $x.Expected) -ForegroundColor Red }
    }
    Write-Host ('{0}/{1} PASS' -f $pass, $results.Count)
    if ($pass -ne $results.Count) { exit 1 }
    exit 0
}

if ($SelfTest) { Invoke-SelfTest }

# ─────────────────────────────────────────────────────────────
# 7. 입력 확인
# ─────────────────────────────────────────────────────────────
if (-not $InputDir -and -not $OrdersCsv) { throw '-InputDir 를 지정하세요.' }
if (-not $OutDir) { $OutDir = Join-Path $TaskRoot 'output' }
if (-not $Now) { $Now = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
if (-not $Month) { $Month = (Get-Date).AddMonths(-1).ToString('yyyy-MM') }
$Month = ConvertTo-Month $Month
if ($null -eq $Month) { throw '-Month 는 yyyy-MM 형식이어야 합니다 (예: 2026-02).' }
if ($Close -and $Reopen) { throw '-Close 와 -Reopen 은 함께 쓸 수 없습니다.' }

function Resolve-InputFile([string]$Explicit, [string]$Name) {
    if ($Explicit) { return $Explicit }
    return Join-Path $InputDir $Name
}
$OrdersCsv = Resolve-InputFile $OrdersCsv $Cfg.files.orders
$SalesCsv = Resolve-InputFile $SalesCsv $Cfg.files.sales
$MappingCsv = Resolve-InputFile $MappingCsv $Cfg.files.mapping
$PlanCsv = Resolve-InputFile $PlanCsv $Cfg.files.plan
$PnlCsv = Resolve-InputFile $PnlCsv $Cfg.files.pnl
$HistoryCsv = Resolve-InputFile $HistoryCsv $Cfg.files.history
if (-not $ClosedDir) { $ClosedDir = Join-Path $InputDir $Cfg.closedDir }
$ClosedRoot = $ClosedDir

foreach ($f in @($OrdersCsv, $SalesCsv, $MappingCsv)) { if (-not (Test-Path $f)) { throw "필수 파일이 없습니다: $f" } }

$MK = Get-MKey $Month
$FY = Get-FY $Month
$FYIdx = Get-FYIndex $Month
$FYStartKey = $MK - ($FYIdx - 1)
$Elapsed = [decimal]$FYIdx / 12
$CostMetrics = @('인건비', '경비')

# ─────────────────────────────────────────────────────────────
# 8. 재오픈 (가장 최근 마감월만)
# ─────────────────────────────────────────────────────────────
$History = @(Read-History $HistoryCsv)
$ClosedMap = Get-ClosedState $History

function Add-History($Entry) {
    if (Test-Path $HistoryCsv) { Copy-Item $HistoryCsv ($HistoryCsv + '.bak') -Force }
    $rows = @($History | ForEach-Object { , @($_.Month, $_.Status, $_.Version, $_.At, $_.Operator, $_.Reason, $_.Hash, $_.Orders, $_.Sales) })
    $rows += , @($Entry.Month, $Entry.Status, $Entry.Version, $Entry.At, $Entry.Operator, $Entry.Reason, $Entry.Hash, $Entry.Orders, $Entry.Sales)
    Write-Csv $HistoryCsv $HistoryHeaders $rows
}

if ($Reopen) {
    if (-not $ClosedMap.ContainsKey($Month)) { throw "$Month 은(는) 마감 상태가 아닙니다." }
    $latestClosed = ($ClosedMap.Keys | Sort-Object | Select-Object -Last 1)
    if ($latestClosed -ne $Month) { throw "재오픈은 가장 최근 마감월($latestClosed)만 가능합니다. 이후 월부터 역순으로 재오픈하세요." }
    if ($Reason.Trim() -eq '') { throw '재오픈 사유(-Reason)를 입력하세요.' }
    $cur = $ClosedMap[$Month]
    $snap = Get-SnapshotDir $Month
    $verDir = Join-Path $snap ('v{0}' -f $cur.Version)
    New-Item -ItemType Directory -Path $verDir -Force | Out-Null
    foreach ($n in @('수주실적.csv', '매출실적.csv', '손익실적.csv')) { $p = Join-Path $snap $n; if (Test-Path $p) { Move-Item $p (Join-Path $verDir $n) -Force } }
    Add-History ([pscustomobject]@{ Month = $Month; Status = '재오픈'; Version = $cur.Version; At = $Now; Operator = $Operator; Reason = $Reason; Hash = $cur.Hash; Orders = $cur.Orders; Sales = $cur.Sales })
    Write-Host ("재오픈 완료: {0} (확정 v{1} 보관 → {2})" -f $Month, $cur.Version, $verDir)
    Write-Host '수정 후 run.bat 으로 검증하고 run_close.bat 으로 다시 마감하세요.'
    exit 0
}

# ─────────────────────────────────────────────────────────────
# 9. 데이터 적재
# ─────────────────────────────────────────────────────────────
$o = Read-Ledger $OrdersCsv '수주' $Cfg.orderColumns '수주실적' $false
$InOrders = @($o.Rows); $HasDept = $o.HasDept
$InSales = @((Read-Ledger $SalesCsv '매출' $Cfg.salesColumns '매출실적' $false).Rows)
$Mapping = @(Read-Mapping $MappingCsv)
$Plan = @{}
if (Test-Path $PlanCsv) { $Plan = Read-Plan $PlanCsv } else { Add-Issue '경고' 'W06' '사업계획' '' '' '' '사업계획.csv 가 없어 목표 대비 달성률을 생략합니다' }
$HasPnl = Test-Path $PnlCsv
$InPnl = @{}
if ($HasPnl) { $InPnl = Read-Pnl $PnlCsv '손익실적' $false } else { Add-Issue '경고' 'W05' '손익실적' '' '' '' '손익실적.csv 가 없어 과제기여·인건비·경비·영업이익·인당 지표를 생략합니다' }

# 대상월 이후 데이터는 보고에서 제외
$future = @($InOrders | Where-Object { $_.Month -gt $Month }).Count + @($InSales | Where-Object { $_.Month -gt $Month }).Count
if ($future -gt 0) { Add-Issue '경고' 'W04' '수주·매출' '' '' '' ("대상월({0}) 이후 데이터 {1}건은 이번 보고에서 제외했습니다" -f $Month, $future) }

# 월별 데이터 선택: 마감월은 스냅샷, 그 외는 입력
$byMonthIn = @{}
foreach ($r in ($InOrders + $InSales)) { if (-not $byMonthIn.ContainsKey($r.Month)) { $byMonthIn[$r.Month] = New-Object System.Collections.Generic.List[object] }; $byMonthIn[$r.Month].Add($r) }

$Orders = New-Object System.Collections.Generic.List[object]
$Sales = New-Object System.Collections.Generic.List[object]
$Pnl = @{}
$snapUsed = 0
$closedKeys = @($ClosedMap.Keys | Sort-Object)
foreach ($cm in $closedKeys) {
    $snap = Read-Snapshot (Get-SnapshotDir $cm)
    $h = $ClosedMap[$cm]
    $inO = @($InOrders | Where-Object { $_.Month -eq $cm }); $inS = @($InSales | Where-Object { $_.Month -eq $cm })
    $inP = $null; if ($InPnl.ContainsKey($cm)) { $inP = $InPnl[$cm] }
    if (($inO.Count + $inS.Count) -gt 0 -or $null -ne $inP) {
        # 입력에도 해당 월이 있으면 마감 당시와 같은지 확인
        # 원장별로 비교: 입력에 그 원장의 해당 월 행이 하나도 없으면 '제공 안 함'으로 보고 비교하지 않음
        $added = @(); $removed = @()
        foreach ($pair in @(@($inO, $snap.Orders), @($inS, $snap.Sales))) {
            if (@($pair[0]).Count -eq 0) { continue }
            $snapCanon = @{}; foreach ($x in $pair[1]) { $snapCanon[(Get-Canon $x)] = $true }
            $inCanon = @{}; foreach ($x in $pair[0]) { $inCanon[(Get-Canon $x)] = $true }
            $added += @($inCanon.Keys | Where-Object { -not $snapCanon.ContainsKey($_) })
            $removed += @($snapCanon.Keys | Where-Object { -not $inCanon.ContainsKey($_) })
        }
        $pnlChanged = ($null -ne $inP -and $null -ne $snap.Pnl -and (Get-PnlCanon $inP) -ne (Get-PnlCanon $snap.Pnl)) -or ($null -ne $inP -and $null -eq $snap.Pnl)
        $ledgerGiven = ($inO.Count + $inS.Count) -gt 0
        if (($ledgerGiven -and ($added.Count + $removed.Count) -gt 0) -or $pnlChanged) {
            $pjts = @(($added + $removed) | ForEach-Object { ($_ -split "`t")[2] } | Select-Object -Unique -First 5) -join ', '
            $msg = '마감(v{0}) 이후 입력이 바뀌었습니다: 추가/변경 {1}건, 삭제/변경 {2}건{3}{4}. 마감 데이터로 보고하며, 반영하려면 재오픈하세요' -f $h.Version, $added.Count, $removed.Count, $(if ($pjts) { " (PJT: $pjts)" } else { '' }), $(if ($pnlChanged) { ', 손익 변경' } else { '' })
            Add-Issue '오류' 'E07' '수주·매출' '' '' $cm $msg
        }
    }
    foreach ($x in $snap.Orders) { $Orders.Add($x) }
    foreach ($x in $snap.Sales) { $Sales.Add($x) }
    if ($null -ne $snap.Pnl) { $Pnl[$cm] = $snap.Pnl }
    $snapUsed++
}
foreach ($x in $InOrders) { if (-not $ClosedMap.ContainsKey($x.Month) -and $x.Month -le $Month) { $Orders.Add($x) } }
foreach ($x in $InSales) { if (-not $ClosedMap.ContainsKey($x.Month) -and $x.Month -le $Month) { $Sales.Add($x) } }
foreach ($k in $InPnl.Keys) { if (-not $ClosedMap.ContainsKey($k) -and $k -le $Month) { $Pnl[$k] = $InPnl[$k] } }
$Orders = @($Orders | Where-Object { $_.Month -le $Month })
$Sales = @($Sales | Where-Object { $_.Month -le $Month })
if ($snapUsed -gt 0) { Add-Issue '정보' 'I01' '마감데이터' '' '' '' ("마감된 {0}개월({1}~{2})은 마감 스냅샷으로 집계했습니다" -f $snapUsed, $closedKeys[0], $closedKeys[-1]) }

# ─────────────────────────────────────────────────────────────
# 10. 데이터 검증 (월 단위)
# ─────────────────────────────────────────────────────────────
$scopeStart = $FYStartKey - 24
$GroupOf = @{}
$missingMap = @{}
foreach ($r in ($Orders + $Sales)) {
    if ((Get-MKey $r.Month) -lt $scopeStart) { continue }
    if ($MaintAsGroup -and $r.Type -eq $MaintType) { continue }
    $basis = if ($MappingBasis -eq 'transaction') { $r.Month } else { $Month }
    $g = Resolve-Group $Mapping $r.RawGroup $basis
    if ($null -eq $g) {
        $key = '{0}|{1}' -f $r.RawGroup, $basis
        if (-not $missingMap.ContainsKey($key)) { $missingMap[$key] = 0; Add-Issue '오류' 'E04' $r.Src $r.Line $r.Pjt $r.Month ("제품군 '{0}' 이(가) 제품군매핑.csv 에 없습니다 (기준월 {1}). 같은 제품군 행은 1건만 표시" -f $r.RawGroup, $basis) }
        $missingMap[$key]++
    }
}

$orderPjts = @{}; foreach ($r in $Orders) { $orderPjts[$r.Pjt] = $true }; foreach ($r in $InOrders) { $orderPjts[$r.Pjt] = $true }
foreach ($r in @($Orders | Where-Object { $_.Month -eq $Month })) {
    if ($r.Net -lt 0) { Add-Issue '경고' 'W01' '수주실적' $r.Line $r.Pjt $r.Month ("순수주가 음수입니다 ({0}원) — 감액·취소 계약인지 확인" -f $r.Net.ToString('#,0', $Inv)) }
    if ($r.Gross -gt 0 -and ($r.Cost1 + $r.Cost2) -gt $r.Gross) { Add-Issue '경고' 'W02' '수주실적' $r.Line $r.Pjt $r.Month '용역비+판매수수료가 수주금액보다 큽니다' }
}
foreach ($r in @($Sales | Where-Object { $_.Month -eq $Month })) {
    if ($r.Net -lt 0) { Add-Issue '경고' 'W01' '매출실적' $r.Line $r.Pjt $r.Month ("순매출이 음수입니다 ({0}원) — 마이너스 세금계산서인지 확인" -f $r.Net.ToString('#,0', $Inv)) }
    if ($r.Gross -gt 0 -and ($r.Cost1 + $r.Cost2) -gt $r.Gross) { Add-Issue '경고' 'W02' '매출실적' $r.Line $r.Pjt $r.Month '외주비가 매출금액보다 큽니다' }
    if (-not $orderPjts.ContainsKey($r.Pjt)) { Add-Issue '경고' 'W03' '매출실적' $r.Line $r.Pjt $r.Month 'PJT코드가 수주실적에 없습니다 — 코드 오입력 또는 수주 누락 확인' }
}
$tgtO = @($Orders | Where-Object { $_.Month -eq $Month }); $tgtS = @($Sales | Where-Object { $_.Month -eq $Month })
if (($tgtO.Count + $tgtS.Count) -eq 0) { Add-Issue '오류' 'E10' '수주·매출' '' '' $Month '대상월 수주·매출 데이터가 0건입니다 — 파일·대상월을 확인하세요' }
if ($HasPnl -and -not $Pnl.ContainsKey($Month)) { Add-Issue '오류' 'E09' '손익실적' '' '' $Month '대상월 손익실적(과제기여·인건비·경비)이 없습니다' }
if (@($Plan.Keys | Where-Object { $_ -like "$FY|*" }).Count -eq 0 -and (Test-Path $PlanCsv)) { Add-Issue '경고' 'W06' '사업계획' '' '' '' ("FY{0} 사업계획이 없어 목표 대비 달성률을 생략합니다" -f $FY) }

# ─────────────────────────────────────────────────────────────
# 11. 마감
# ─────────────────────────────────────────────────────────────
$ErrCount = @($Issues | Where-Object { $_.Level -eq '오류' }).Count
$CloseMessage = $null
$CloseFailed = $false
$ChangeRows = @()
if ($Close) {
    $blocking = New-Object System.Collections.Generic.List[string]
    if ($ClosedMap.ContainsKey($Month)) { $blocking.Add(("{0} 은(는) 이미 마감되었습니다 (v{1}). 수정하려면 먼저 재오픈하세요" -f $Month, $ClosedMap[$Month].Version)) }
    else {
        $lastClosed = $null; if ($closedKeys.Count -gt 0) { $lastClosed = $closedKeys[-1] }
        if ($null -ne $lastClosed -and (Get-MStr ((Get-MKey $lastClosed) + 1)) -ne $Month) {
            $blocking.Add(("마감은 월 순서대로 합니다. 최근 마감월이 {0} 이므로 다음 마감 대상은 {1} 입니다" -f $lastClosed, (Get-MStr ((Get-MKey $lastClosed) + 1))))
            Add-Issue '오류' 'E08' '마감' '' '' $Month $blocking[-1]
        }
    }
    if ($ErrCount -gt 0) { $blocking.Add(("검증 오류 {0}건이 있어 마감할 수 없습니다 (검증결과.csv 확인)" -f $ErrCount)) }
    if ($blocking.Count -gt 0) {
        $CloseFailed = $true
        $CloseMessage = '마감 실패: ' + ($blocking -join ' / ')
    }
    else {
        $prevVer = @($History | Where-Object { $_.Month -eq $Month -and $_.Status -eq '마감' }).Count
        $ver = $prevVer + 1
        $pn = $null; if ($Pnl.ContainsKey($Month)) { $pn = $Pnl[$Month] }
        $hash = Get-MonthHash $tgtO $tgtS $pn
        $snapDir = Get-SnapshotDir $Month
        Write-Snapshot $snapDir $tgtO $tgtS $pn
        if ($prevVer -gt 0) {
            $old = Read-Snapshot (Join-Path $snapDir ('v{0}' -f $prevVer))
            $oldC = @{}; foreach ($x in ($old.Orders + $old.Sales)) { $oldC[(Get-Canon $x)] = $x }
            $newC = @{}; foreach ($x in ($tgtO + $tgtS)) { $newC[(Get-Canon $x)] = $x }
            $cr = New-Object System.Collections.Generic.List[object]
            foreach ($k in $newC.Keys) { if (-not $oldC.ContainsKey($k)) { $x = $newC[$k]; $cr.Add(@('추가', $x.Kind, $x.Pjt, $x.PjtName, $x.RawGroup, $x.Type, (Format-Dec $x.Gross), (Format-Dec $x.Net))) } }
            foreach ($k in $oldC.Keys) { if (-not $newC.ContainsKey($k)) { $x = $oldC[$k]; $cr.Add(@('삭제', $x.Kind, $x.Pjt, $x.PjtName, $x.RawGroup, $x.Type, (Format-Dec $x.Gross), (Format-Dec $x.Net))) } }
            $ChangeRows = $cr.ToArray()
        }
        $entry = [pscustomobject]@{ Month = $Month; Status = '마감'; Version = $ver; At = $Now; Operator = $Operator; Reason = $(if ($Reason) { $Reason } else { '정기 마감' }); Hash = $hash; Orders = $tgtO.Count; Sales = $tgtS.Count }
        Add-History $entry
        $History = @(Read-History $HistoryCsv)
        $ClosedMap = Get-ClosedState $History
        $CloseMessage = "마감 완료: {0} 확정 v{1} (수주 {2}건 · 매출 {3}건, 해시 {4})" -f $Month, $ver, $tgtO.Count, $tgtS.Count, $hash
    }
}

# ─────────────────────────────────────────────────────────────
# 12. 집계
# ─────────────────────────────────────────────────────────────
function Get-ReportGroup($r) {
    if ($MaintAsGroup -and $r.Type -eq $MaintType) { return $MaintType }
    $basis = if ($MappingBasis -eq 'transaction') { $r.Month } else { $Month }
    $g = Resolve-Group $Mapping $r.RawGroup $basis
    if ($null -eq $g) { return '(미매핑)' }
    return $g
}
foreach ($r in ($Orders + $Sales)) { $r | Add-Member -NotePropertyName Group -NotePropertyValue (Get-ReportGroup $r) -Force }

$Covered = @{}
foreach ($r in ($Orders + $Sales)) { $Covered[$r.Month] = $true }

function Test-Covered([int]$fromK, [int]$toK) {
    for ($k = $fromK; $k -le $toK; $k++) { if (-not $Covered.ContainsKey((Get-MStr $k))) { return $false } }
    return $true
}

$OrdersByMonth = @{}; foreach ($r in $Orders) { if (-not $OrdersByMonth.ContainsKey($r.Month)) { $OrdersByMonth[$r.Month] = New-Object System.Collections.Generic.List[object] }; $OrdersByMonth[$r.Month].Add($r) }
$SalesByMonth = @{}; foreach ($r in $Sales) { if (-not $SalesByMonth.ContainsKey($r.Month)) { $SalesByMonth[$r.Month] = New-Object System.Collections.Generic.List[object] }; $SalesByMonth[$r.Month].Add($r) }

function Get-RowsIn($ByMonth, [int]$fromK, [int]$toK) {
    $list = New-Object System.Collections.Generic.List[object]
    for ($k = $fromK; $k -le $toK; $k++) { $m = Get-MStr $k; if ($ByMonth.ContainsKey($m)) { foreach ($x in $ByMonth[$m]) { $list.Add($x) } } }
    return , $list.ToArray()
}
function Get-Sum($rows, [scriptblock]$Filter) {
    $s = [decimal]0
    foreach ($x in $rows) { if ($null -eq $Filter -or (& $Filter $x)) { $s += $x.Net } }
    return $s
}
function Get-PnlSum([int]$fromK, [int]$toK, [string]$Field) {
    if (-not $HasPnl) { return $null }
    $s = [decimal]0
    for ($k = $fromK; $k -le $toK; $k++) { $m = Get-MStr $k; if (-not $Pnl.ContainsKey($m)) { return $null }; $s += $Pnl[$m].$Field }
    return $s
}
function Get-AvgHeadcount([int]$fromK, [int]$toK) {
    if (-not $HasPnl) { return $null }
    $s = [decimal]0; $n = 0
    for ($k = $fromK; $k -le $toK; $k++) { $m = Get-MStr $k; if (-not $Pnl.ContainsKey($m) -or -not $Pnl[$m].HasHeadcount) { return $null }; $s += $Pnl[$m].Headcount; $n++ }
    if ($n -eq 0) { return $null }
    return $s / $n
}

# 기간 정의: 0=당년, 1=전년, 2=전전년
$Periods = @()
foreach ($off in @(2, 1, 0)) {
    $pk = $MK - 12 * $off; $ps = $FYStartKey - 12 * $off
    $Periods += [pscustomobject]@{
        Off = $off; Label = (Get-MStr $pk).Substring(2); FyLabel = ('FY{0}' -f ($FY - $off))
        MonthKey = $pk; YtdFrom = $ps; YtdTo = $pk
        MonthOk = (Test-Covered $pk $pk); YtdOk = (Test-Covered $ps $pk)
    }
}

$MetricNames = @('순수주', '순매출', '과제기여', '인건비', '경비', '영업이익')
function Get-Metrics([int]$fromK, [int]$toK, [bool]$ok) {
    $res = [ordered]@{}
    foreach ($n in $MetricNames) { $res[$n] = $null }
    if (-not $ok) { return $res }
    $res['순수주'] = Get-Sum (Get-RowsIn $OrdersByMonth $fromK $toK) $null
    $res['순매출'] = Get-Sum (Get-RowsIn $SalesByMonth $fromK $toK) $null
    $res['과제기여'] = Get-PnlSum $fromK $toK 'Project'
    $res['인건비'] = Get-PnlSum $fromK $toK 'Labor'
    $res['경비'] = Get-PnlSum $fromK $toK 'Expense'
    if ($null -ne $res['과제기여'] -and $null -ne $res['인건비'] -and $null -ne $res['경비']) {
        $res['영업이익'] = $res['순매출'] + $res['과제기여'] - $res['인건비'] - $res['경비']
    }
    return $res
}

$MonthMetrics = @{}; $YtdMetrics = @{}
foreach ($p in $Periods) {
    $MonthMetrics[$p.Off] = Get-Metrics $p.MonthKey $p.MonthKey $p.MonthOk
    $YtdMetrics[$p.Off] = Get-Metrics $p.YtdFrom $p.YtdTo $p.YtdOk
}
$ShowMetrics = @($MetricNames | Where-Object { $null -ne $MonthMetrics[0][$_] -or $null -ne $YtdMetrics[0][$_] })

# 제품군 순서
$GroupOrder = @{}
foreach ($e in $Mapping) { if (-not $GroupOrder.ContainsKey($e.Report) -or $e.Order -lt $GroupOrder[$e.Report]) { $GroupOrder[$e.Report] = $e.Order } }
if ($MaintAsGroup) { $GroupOrder[$MaintType] = 100000 }
$GroupOrder['(미매핑)'] = 100001
$AllGroups = @(($Orders + $Sales) | ForEach-Object { $_.Group } | Select-Object -Unique)
$Groups = @($AllGroups | Sort-Object @{ Expression = { if ($GroupOrder.ContainsKey($_)) { $GroupOrder[$_] } else { 99999 } } }, @{ Expression = { $_ } })

function Get-GroupTable($ByMonth, [string]$Mode) {
    # 반환: 행 목록 [Group, v2, v1, v0]
    $rows = New-Object System.Collections.Generic.List[object]
    $tot = @{}
    $cache = @{}
    foreach ($p in $Periods) {
        $ok = if ($Mode -eq 'month') { $p.MonthOk } else { $p.YtdOk }
        $from = if ($Mode -eq 'month') { $p.MonthKey } else { $p.YtdFrom }
        $cache[$p.Off] = @{ Ok = $ok; Rows = (Get-RowsIn $ByMonth $from $p.MonthKey) }
    }
    foreach ($g in $Groups) {
        $vals = @{}
        $any = $false
        foreach ($p in $Periods) {
            $c = $cache[$p.Off]
            if (-not $c.Ok) { $vals[$p.Off] = $null; continue }
            $v = Get-Sum $c.Rows { param($x) $x.Group -eq $g }
            $vals[$p.Off] = $v
            if ($v -ne 0) { $any = $true }
        }
        if ($any) { $rows.Add([pscustomobject]@{ Group = $g; V = $vals }) }
    }
    foreach ($p in $Periods) { $c = $cache[$p.Off]; $tot[$p.Off] = $(if ($c.Ok) { Get-Sum $c.Rows $null } else { $null }) }
    return @{ Rows = $rows.ToArray(); Total = $tot }
}

$GT = @{
    'orders|month' = Get-GroupTable $OrdersByMonth 'month'
    'orders|ytd'   = Get-GroupTable $OrdersByMonth 'ytd'
    'sales|month'  = Get-GroupTable $SalesByMonth 'month'
    'sales|ytd'    = Get-GroupTable $SalesByMonth 'ytd'
}

# 부서별 누계 순수주
$DeptRows = @()
if ($HasDept) {
    $depts = @($Orders | Where-Object { $_.Dept -ne '' } | ForEach-Object { $_.Dept } | Select-Object -Unique | Sort-Object)
    foreach ($d in $depts) {
        $cur = Get-Sum (Get-RowsIn $OrdersByMonth $FYStartKey $MK) { param($x) $x.Dept -eq $d }
        $py = $null; if ($Periods[1].YtdOk) { $py = Get-Sum (Get-RowsIn $OrdersByMonth ($FYStartKey - 12) ($MK - 12)) { param($x) $x.Dept -eq $d } }
        $DeptRows += [pscustomobject]@{ Dept = $d; Cur = $cur; Py = $py; Plan = (Get-Plan $Plan $FY '부서' $d '순수주') }
    }
}

# 월별 추이 (사업연도 월 1~12)
$Trend = @()
foreach ($p in $Periods) {
    $cumO = [decimal]0; $cumS = [decimal]0
    for ($i = 0; $i -lt 12; $i++) {
        $k = $p.YtdFrom + $i
        $m = Get-MStr $k
        # 당년은 대상월까지, 과거 사업연도는 12개월 전체(대상월 이전 데이터만)
        $lim = if ($p.Off -eq 0) { $p.YtdTo } else { $MK }
        $has = ($k -le $lim) -and $Covered.ContainsKey($m)
        $mo = $null; $ms = $null; $co = $null; $cs = $null
        if ($has) {
            $mo = Get-Sum (Get-RowsIn $OrdersByMonth $k $k) $null; $ms = Get-Sum (Get-RowsIn $SalesByMonth $k $k) $null
            $cumO += $mo; $cumS += $ms; $co = $cumO; $cs = $cumS
        }
        $Trend += [pscustomobject]@{ Fy = $p.FyLabel; Off = $p.Off; Idx = $i + 1; Month = $m; MonthOrders = $mo; MonthSales = $ms; CumOrders = $co; CumSales = $cs }
    }
}

# 인당 생산성 (누계 평균인원 기준)
$People = @()
foreach ($p in $Periods) {
    if (-not $p.YtdOk) { continue }
    $hc = Get-AvgHeadcount $p.YtdFrom $p.YtdTo
    if ($null -eq $hc -or $hc -eq 0) { continue }
    $ytd = $YtdMetrics[$p.Off]
    $People += [pscustomobject]@{ Off = $p.Off; Label = $p.Label; Avg = $hc; OrdersPer = $ytd['순수주'] / $hc; SalesPer = $ytd['순매출'] / $hc }
}

# ─────────────────────────────────────────────────────────────
# 13. 상태·요약 문구
# ─────────────────────────────────────────────────────────────
$ErrCount = @($Issues | Where-Object { $_.Level -eq '오류' }).Count
$WarnCount = @($Issues | Where-Object { $_.Level -eq '경고' }).Count
if ($ClosedMap.ContainsKey($Month)) { $StatusText = '확정 v{0} ({1} 마감, {2})' -f $ClosedMap[$Month].Version, $ClosedMap[$Month].At, $ClosedMap[$Month].Operator; $IsFinal = $true }
else {
    $reopened = @($History | Where-Object { $_.Month -eq $Month } | Select-Object -Last 1)
    if ($reopened.Count -gt 0 -and $reopened[0].Status -eq '재오픈') { $StatusText = '초안 — 재오픈 중 (직전 확정 v{0}, 사유: {1})' -f $reopened[0].Version, $reopened[0].Reason }
    else { $StatusText = '초안 (미마감)' }
    $IsFinal = $false
}

function Get-Headline {
    $lines = @()
    $m0 = $MonthMetrics[0]; $m1 = $MonthMetrics[1]; $y0 = $YtdMetrics[0]; $y1 = $YtdMetrics[1]
    $mm = [int]$Month.Substring(5, 2)
    foreach ($n in @('순수주', '순매출')) {
        $s = '{0}월 {1} {2}{3}' -f $mm, $n, (Format-Num $m0[$n]), $UnitLabel
        if ($null -ne $m1[$n]) { $s += ' (전년 동월 대비 {0}, {1})' -f (Format-Diff $m0[$n] $m1[$n]), (Format-Rate $m0[$n] $m1[$n]) }
        $s2 = '누계 {0} {1}{2}' -f $n, (Format-Num $y0[$n]), $UnitLabel
        if ($null -ne $y1[$n]) { $s2 += ' (전년 동기 대비 {0}, {1})' -f (Format-Diff $y0[$n] $y1[$n]), (Format-Rate $y0[$n] $y1[$n]) }
        $lines += $s + ' · ' + $s2
    }
    if ($null -ne $y0['영업이익']) {
        $s = '누계 영업이익 {0}{1}' -f (Format-Num $y0['영업이익']), $UnitLabel
        if ($null -ne $y1['영업이익']) { $s += ' (전년 동기 대비 {0})' -f (Format-Diff $y0['영업이익'] $y1['영업이익']) }
        if ($null -ne $m0['영업이익']) { $s += ' · {0}월 당월 {1}{2}' -f $mm, (Format-Num $m0['영업이익']), $UnitLabel }
        $lines += $s
    }
    foreach ($kind in @(@('orders', '순수주'), @('sales', '순매출'))) {
        $tb = $GT[$kind[0] + '|ytd']
        if ($null -eq $tb.Total[1]) { continue }
        $d = @($tb.Rows | Where-Object { $null -ne $_.V[0] -and $null -ne $_.V[1] } | ForEach-Object { [pscustomobject]@{ G = $_.Group; D = $_.V[0] - $_.V[1] } })
        $up = @($d | Where-Object { (Round-Unit $_.D) -gt 0 } | Sort-Object D -Descending | Select-Object -First 2 | ForEach-Object { '{0} {1}' -f $_.G, (Format-Diff $_.D 0) })
        $dn = @($d | Where-Object { (Round-Unit $_.D) -lt 0 } | Sort-Object D | Select-Object -First 2 | ForEach-Object { '{0} {1}' -f $_.G, (Format-Diff $_.D 0) })
        $s = '누계 {0} 증감 — 증가: {1} / 감소: {2}' -f $kind[1], $(if ($up) { $up -join ', ' } else { '없음' }), $(if ($dn) { $dn -join ', ' } else { '없음' })
        $lines += $s
    }
    $mt = @($GT['orders|ytd'].Rows | Where-Object { $_.Group -eq $MaintType })
    if ($mt.Count -gt 0 -and $GT['orders|ytd'].Total[0] -gt 0) {
        $s = '누계 순수주 중 {0} 비중 {1}' -f $MaintType, (Format-Pct ($mt[0].V[0] / $GT['orders|ytd'].Total[0]))
        if ($null -ne $mt[0].V[1] -and $GT['orders|ytd'].Total[1] -gt 0) { $s += ' (전년 동기 {0})' -f (Format-Pct ($mt[0].V[1] / $GT['orders|ytd'].Total[1])) }
        $lines += $s
    }
    return $lines
}
$Headline = @(Get-Headline)

# ─────────────────────────────────────────────────────────────
# 14. 출력 — 집계 CSV
# ─────────────────────────────────────────────────────────────
$Out = Join-Path $OutDir ($Month -replace '-', '')
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out -Force | Out-Null }
function N($v) { if ($null -eq $v) { return '' } return Format-Dec ([decimal]$v) }

$csv = @()
foreach ($kind in @('month', 'ytd')) {
    $mets = if ($kind -eq 'month') { $MonthMetrics } else { $YtdMetrics }
    foreach ($n in $ShowMetrics) {
        $csv += , @($(if ($kind -eq 'month') { '당월' } else { '누계' }), $n, (N $mets[2][$n]), (N $mets[1][$n]), (N $mets[0][$n]), $(if ($null -ne $mets[0][$n] -and $null -ne $mets[1][$n]) { N ($mets[0][$n] - $mets[1][$n]) } else { '' }))
    }
}
Write-Csv (Join-Path $Out '집계_전사.csv') @('기간', '지표', ('{0}(원)' -f $Periods[0].Label), ('{0}(원)' -f $Periods[1].Label), ('{0}(원)' -f $Periods[2].Label), '전년대비증감(원)') $csv

$csv = @()
foreach ($k in @('orders|month', 'orders|ytd', 'sales|month', 'sales|ytd')) {
    $parts = $k -split '\|'
    $kn = if ($parts[0] -eq 'orders') { '순수주' } else { '순매출' }
    $pn = if ($parts[1] -eq 'month') { '당월' } else { '누계' }
    foreach ($r in $GT[$k].Rows) { $csv += , @($kn, $pn, $r.Group, (N $r.V[2]), (N $r.V[1]), (N $r.V[0])) }
    $csv += , @($kn, $pn, 'TOTAL', (N $GT[$k].Total[2]), (N $GT[$k].Total[1]), (N $GT[$k].Total[0]))
}
Write-Csv (Join-Path $Out '집계_제품군.csv') @('지표', '기간', '제품군', ('{0}(원)' -f $Periods[0].Label), ('{0}(원)' -f $Periods[1].Label), ('{0}(원)' -f $Periods[2].Label)) $csv

if ($DeptRows.Count -gt 0) {
    Write-Csv (Join-Path $Out '집계_부서.csv') @('부서', '누계순수주(원)', '전년동기(원)', '연간목표(원)') (@($DeptRows | ForEach-Object { , @($_.Dept, (N $_.Cur), (N $_.Py), (N $_.Plan)) }))
}
Write-Csv (Join-Path $Out '집계_월별추이.csv') @('사업연도', '순번', '월', '월순수주(원)', '월순매출(원)', '누적순수주(원)', '누적순매출(원)') (@($Trend | ForEach-Object { , @($_.Fy, $_.Idx, $_.Month, (N $_.MonthOrders), (N $_.MonthSales), (N $_.CumOrders), (N $_.CumSales)) }))

$sortedIssues = @($Issues | Sort-Object @{ Expression = { switch ($_.Level) { '오류' { 0 } '경고' { 1 } default { 2 } } } }, Code, File, Line)
Write-Csv (Join-Path $Out '검증결과.csv') @('수준', '코드', '파일', '행', 'PJT코드', '월', '내용') (@($sortedIssues | ForEach-Object { , @($_.Level, $_.Code, $_.File, $_.Line, $_.Pjt, $_.Month, $_.Message) }))
if ($ChangeRows.Count -gt 0) { Write-Csv (Join-Path $Out '변경내역.csv') @('변경', '원장', 'PJT코드', 'PJT명칭', '제품군', '구분', '금액(원)', '순액(원)') $ChangeRows }

# ─────────────────────────────────────────────────────────────
# 15. 출력 — 요약.md
# ─────────────────────────────────────────────────────────────
$mm = [int]$Month.Substring(5, 2)
$fyFrom = Get-MStr $FYStartKey
$md = New-Object System.Text.StringBuilder
function A([string]$s) { [void]$md.AppendLine($s) }
function MdRow($cells) { A ('| ' + ($cells -join ' | ') + ' |') }

A ('# 경영실적 보고 — {0}년 {1}월' -f $Month.Substring(0, 4), $mm)
A ''
A ('| 항목 | 내용 |')
A ('|------|------|')
A ('| 보고 범위 | {0} 당월 · FY{1} 누계({2} ~ {0}) |' -f $Month, $FY, $fyFrom)
A ('| 상태 | **{0}** |' -f $StatusText)
A ('| 검증 | 오류 {0}건 · 경고 {1}건 |' -f $ErrCount, $WarnCount)
A ('| 단위 | {0} (원 단위 합계를 반올림, 합계와 내역 끝자리가 다를 수 있음) |' -f $UnitLabel)
A ('| 제품군 체계 | {0} |' -f $(if ($MappingBasis -eq 'transaction') { '거래월 기준 (과거 실적은 당시 제품군)' } else { "보고월($Month) 기준으로 과거 실적까지 재분류" }))
A ('| 실행 | {0} · 수주 {1}건 · 매출 {2}건 (집계 대상) |' -f $Now, $Orders.Count, $Sales.Count)
A ''
if ($CloseMessage) { A ('> {0}' -f $CloseMessage); A '' }
if (-not $IsFinal -and $ErrCount -gt 0) { A ('> ⚠️ 검증 오류가 있어 이 보고서는 **초안**입니다. 아래 §9와 `검증결과.csv`를 보고 수정한 뒤 다시 실행하세요.'); A '' }

A '## 1. 요약'
A ''
foreach ($l in $Headline) { A ('- ' + $l) }
A ''

function Write-MetricTable([string]$Title, $Mets) {
    A $Title
    A ''
    MdRow @('지표', $Periods[0].Label, $Periods[1].Label, $Periods[2].Label, '전년대비 증감액', '증감률')
    MdRow @('------', '---:', '---:', '---:', '---:', '---:')
    foreach ($n in $ShowMetrics) {
        MdRow @($n, (Format-Num $Mets[2][$n]), (Format-Num $Mets[1][$n]), (Format-Num $Mets[0][$n]), (Format-Diff $Mets[0][$n] $Mets[1][$n]), $(if ($n -eq '영업이익') { '-' } else { Format-Rate $Mets[0][$n] $Mets[1][$n] }))
    }
    A ''
}
Write-MetricTable ('## 2. 전사 당월 실적 ({0}월, 3개년)' -f $mm) $MonthMetrics
Write-MetricTable ('## 3. 전사 누계 실적 ({0} ~ {1}, 3개년)' -f (Get-MStr $FYStartKey).Substring(2), $Month.Substring(2)) $YtdMetrics

A ('## 4. 목표 대비 (FY{0}, 경과 {1}/12개월 · 경과율 {2})' -f $FY, $FYIdx, (Format-Pct ($FYIdx / 12)))
A ''
$planShown = $false
$planRows = @()
foreach ($n in $ShowMetrics) {
    $pl = Get-Plan $Plan $FY '전사' '전사' $n
    if ($null -eq $pl) { continue }
    $planShown = $true
    $act = $YtdMetrics[0][$n]
    $fc = if ($null -ne $act) { $act / $FYIdx * 12 } else { $null }
    $planRows += [pscustomobject]@{ Name = $n; Plan = $pl; Act = $act; Gap = $(if ($null -ne $act) { $act - $pl } else { $null }); Rate = $(if ($pl -ne 0 -and $null -ne $act) { $act / $pl } else { $null }); Fc = $fc; FcRate = $(if ($pl -ne 0 -and $null -ne $fc) { $fc / $pl } else { $null }) }
}
if ($planShown) {
    MdRow @('지표', '연간목표', '누계실적', '목표부족액', '달성률', '연환산 예상', '예상 달성률')
    MdRow @('------', '---:', '---:', '---:', '---:', '---:', '---:')
    foreach ($r in $planRows) { MdRow @($r.Name, (Format-Num $r.Plan), (Format-Num $r.Act), (Format-Num $r.Gap), (Format-Pct $r.Rate), (Format-Num $r.Fc), (Format-Pct $r.FcRate)) }
    A ''
    A '※ 연환산 예상 = 누계 ÷ 경과월 × 12 (계절성을 반영하지 않은 단순 환산)'
}
else { A '사업계획(전사) 데이터가 없어 생략했습니다.' }
A ''

$sec = 5
foreach ($kind in @(@('orders', '순수주'), @('sales', '순매출'))) {
    A ('## {0}. 제품군별 {1}' -f $sec, $kind[1])
    A ''
    foreach ($pm in @(@('month', ('당월({0}월)' -f $mm)), @('ytd', '누계'))) {
        $tb = $GT[$kind[0] + '|' + $pm[0]]
        $withPlan = ($pm[0] -eq 'ytd')
        A ('### {0} {1}' -f $pm[1], $kind[1])
        A ''
        $hdr = @('제품군', $Periods[0].Label, $Periods[1].Label, $Periods[2].Label, '전년대비 증감액', '증감률')
        $al = @('------', '---:', '---:', '---:', '---:', '---:')
        if ($withPlan) { $hdr += @('연간목표', '달성률'); $al += @('---:', '---:') }
        MdRow $hdr; MdRow $al
        foreach ($r in $tb.Rows) {
            $cells = @($r.Group, (Format-Num $r.V[2]), (Format-Num $r.V[1]), (Format-Num $r.V[0]), (Format-Diff $r.V[0] $r.V[1]), (Format-Rate $r.V[0] $r.V[1]))
            if ($withPlan) { $pl = Get-Plan $Plan $FY '제품군' $r.Group $kind[1]; $cells += @((Format-Num $pl), $(if ($null -ne $pl -and $pl -ne 0) { Format-Pct ($r.V[0] / $pl) } else { '-' })) }
            MdRow $cells
        }
        $cells = @('**TOTAL**', (Format-Num $tb.Total[2]), (Format-Num $tb.Total[1]), (Format-Num $tb.Total[0]), (Format-Diff $tb.Total[0] $tb.Total[1]), (Format-Rate $tb.Total[0] $tb.Total[1]))
        if ($withPlan) { $pl = Get-Plan $Plan $FY '전사' '전사' $kind[1]; $cells += @((Format-Num $pl), $(if ($null -ne $pl -and $pl -ne 0) { Format-Pct ($tb.Total[0] / $pl) } else { '-' })) }
        MdRow $cells
        $mt = @($tb.Rows | Where-Object { $_.Group -eq $MaintType })
        if ($mt.Count -gt 0) {
            $share = @(); foreach ($o in @(2, 1, 0)) { $share += $(if ($null -ne $tb.Total[$o] -and $tb.Total[$o] -ne 0) { Format-Pct ($mt[0].V[$o] / $tb.Total[$o]) } else { '-' }) }
            $cells = @(('{0} 비중' -f $MaintType)) + $share + @('', '')
            if ($withPlan) { $cells += @('', '') }
            MdRow $cells
        }
        A ''
    }
    $sec++
}

A ('## {0}. 부서별 누계 순수주' -f $sec)
A ''
if ($DeptRows.Count -gt 0) {
    MdRow @('부서', ('누계 {0}' -f $Periods[2].Label), ('전년 동기 {0}' -f $Periods[1].Label), '증감액', '증감률', '연간목표', '달성률')
    MdRow @('------', '---:', '---:', '---:', '---:', '---:', '---:')
    foreach ($d in $DeptRows) { MdRow @($d.Dept, (Format-Num $d.Cur), (Format-Num $d.Py), (Format-Diff $d.Cur $d.Py), (Format-Rate $d.Cur $d.Py), (Format-Num $d.Plan), $(if ($null -ne $d.Plan -and $d.Plan -ne 0) { Format-Pct ($d.Cur / $d.Plan) } else { '-' })) }
}
else { A '수주실적에 부서 열이 없어 생략했습니다.' }
A ''
$sec++

A ('## {0}. 인원·인당 생산성 (누계 평균인원 기준)' -f $sec)
A ''
if ($People.Count -gt 0) {
    MdRow @('구분', '평균인원(명)', '인당 순수주', '연환산', '인당 순매출', '연환산')
    MdRow @('------', '---:', '---:', '---:', '---:', '---:')
    foreach ($p in ($People | Sort-Object Off -Descending)) {
        MdRow @(('누계 ' + $p.Label), ([math]::Round($p.Avg, 1, [MidpointRounding]::AwayFromZero)).ToString('0.0', $Inv), (Format-Num $p.OrdersPer), (Format-Num ($p.OrdersPer / $FYIdx * 12)), (Format-Num $p.SalesPer), (Format-Num ($p.SalesPer / $FYIdx * 12)))
    }
}
else { A '손익실적(월말인원)이 없어 생략했습니다.' }
A ''
$sec++

A ('## {0}. 월별 누적 추이 (순수주 / 순매출)' -f $sec)
A ''
$hdr = @('월'); $al = @('---:')
foreach ($p in $Periods) { $hdr += @(('{0} 누적순수주' -f $p.FyLabel), ('{0} 누적순매출' -f $p.FyLabel)); $al += @('---:', '---:') }
MdRow $hdr; MdRow $al
for ($i = 1; $i -le 12; $i++) {
    $mon = (($FyStart + $i - 2) % 12) + 1
    $cells = @(('{0}월' -f $mon))
    foreach ($p in $Periods) { $t = @($Trend | Where-Object { $_.Off -eq $p.Off -and $_.Idx -eq $i })[0]; $cells += @((Format-Num $t.CumOrders), (Format-Num $t.CumSales)) }
    MdRow $cells
}
A ''
$sec++

A ('## {0}. 검증 결과' -f $sec)
A ''
if ($sortedIssues.Count -eq 0) { A '오류·경고 없음' }
else {
    MdRow @('수준', '코드', '파일', '행', 'PJT코드', '월', '내용')
    MdRow @('---', '---', '---', '---:', '---', '---', '---')
    foreach ($x in ($sortedIssues | Select-Object -First 30)) { MdRow @($x.Level, $x.Code, $x.File, $x.Line, $x.Pjt, $x.Month, ($x.Message -replace '\|', '/')) }
    if ($sortedIssues.Count -gt 30) { A ''; A ('… 외 {0}건은 `검증결과.csv` 참고' -f ($sortedIssues.Count - 30)) }
}
A ''
$sec++

A ('## {0}. 마감 현황' -f $sec)
A ''
$hist = @($History | Select-Object -Last 12)
if ($hist.Count -eq 0) { A '마감 이력 없음' }
else {
    MdRow @('마감월', '상태', '버전', '일시', '실행자', '사유')
    MdRow @('---', '---', '---:', '---', '---', '---')
    foreach ($h in $hist) { MdRow @($h.Month, $h.Status, $h.Version, $h.At, $h.Operator, $h.Reason) }
}
if ($ChangeRows.Count -gt 0) { A ''; A ('직전 확정본 대비 변경 {0}건 → `변경내역.csv`' -f $ChangeRows.Count) }
Write-Text (Join-Path $Out '요약.md') $md.ToString()

# ─────────────────────────────────────────────────────────────
# 16. 출력 — 경영실적보고서.html
# ─────────────────────────────────────────────────────────────
function Esc([string]$s) { if ($null -eq $s) { return '' } return [System.Net.WebUtility]::HtmlEncode($s) }
function Td([string]$s, [string]$cls = '') {
    $c = $cls
    if ($s -like '▲*') { $c += ' up' } elseif ($s -like '▼*') { $c += ' down' } elseif ($s -like '(*') { $c += ' neg' }
    return ('<td class="{0}">{1}</td>' -f $c.Trim(), (Esc $s))
}
function RateTd($rate, $base = 1, [bool]$Cost = $false) {
    # 색은 기준(base) 대비 진도로 판단: 누계 달성률은 경과율, 연환산 예상은 100%
    if ($null -eq $rate) { return '<td>-</td>' }
    $pace = if ($base -ne 0) { $rate / $base } else { $rate }
    if ($Cost) { $c = if ($pace -le 1) { 'ok' } elseif ($pace -le 1.1) { 'mid' } else { 'low' } }
    else { $c = if ($pace -ge 1) { 'ok' } elseif ($pace -ge 0.9) { 'mid' } else { 'low' } }
    return ('<td><span class="pill {0}">{1}</span></td>' -f $c, (Format-Pct $rate))
}

function Get-TrendSvg([string]$Field, [string]$Title) {
    $w = 640; $h = 240; $l = 56; $r = 16; $t = 28; $b = 28
    $max = [decimal]1
    foreach ($x in $Trend) { $v = $x.$Field; if ($null -ne $v -and $v -gt $max) { $max = $v } }
    $max = [decimal]([math]::Ceiling([double]($max / $Unit) / 1000) * 1000) * $Unit
    if ($max -le 0) { $max = $Unit }
    $sx = ($w - $l - $r) / 11.0; $sy = ($h - $t - $b) / [double]$max
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg viewBox="0 0 {0} {1}" role="img" aria-label="{2}">' -f $w, $h, (Esc $Title)))
    for ($g = 0; $g -le 4; $g++) {
        $y = $t + ($h - $t - $b) * (1 - $g / 4.0); $lab = (Round-Unit ($max * $g / 4)).ToString('#,0', $Inv)
        [void]$sb.Append(('<line class="grid" x1="{0}" x2="{1}" y1="{2:0.#}" y2="{2:0.#}"/><text class="ax" x="{3}" y="{4:0.#}" text-anchor="end">{5}</text>' -f $l, ($w - $r), $y, ($l - 6), ($y + 4), $lab))
    }
    for ($i = 1; $i -le 12; $i++) { $mon = (($FyStart + $i - 2) % 12) + 1; [void]$sb.Append(('<text class="ax" x="{0:0.#}" y="{1}" text-anchor="middle">{2}월</text>' -f ($l + ($i - 1) * $sx), ($h - 8), $mon)) }
    $cls = @{ 2 = 's2'; 1 = 's1'; 0 = 's0' }
    foreach ($p in $Periods) {
        $pts = @($Trend | Where-Object { $_.Off -eq $p.Off -and $null -ne $_.$Field } | ForEach-Object { '{0:0.#},{1:0.#}' -f ($l + ($_.Idx - 1) * $sx), ($h - $b - [double]$_.$Field * $sy) })
        if ($pts.Count -gt 0) { [void]$sb.Append(('<polyline class="{0}" points="{1}"/>' -f $cls[$p.Off], ($pts -join ' '))) }
    }
    $lx = $l + 8
    foreach ($p in $Periods) { [void]$sb.Append(('<rect class="{0}f" x="{1}" y="8" width="10" height="10" rx="2"/><text class="lg" x="{2}" y="17">{3}</text>' -f $cls[$p.Off], $lx, ($lx + 14), $p.FyLabel)); $lx += 80 }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

$css = @'
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d2330;--sub:#5d6575;--line:#e3e6ec;--head:#f1f3f7;--up:#c62828;--down:#1565c0;--ok:#2e7d32;--mid:#b26a00;--low:#c62828;--s0:#2e7d32;--s1:#7a869a;--s2:#c3cad6;--draft:#fff4e5;--final:#e8f5e9}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--card:#1c2027;--ink:#e6e9ef;--sub:#a3abba;--line:#2c323c;--head:#232832;--up:#ef5350;--down:#64b5f6;--ok:#66bb6a;--mid:#ffb74d;--low:#ef5350;--s0:#66bb6a;--s1:#9aa5b8;--s2:#4a5363;--draft:#3a2e1c;--final:#1d3320}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.55 "Malgun Gothic","Apple SD Gothic Neo",system-ui,sans-serif}
main{max-width:1080px;margin:0 auto;padding:24px 16px 48px}h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:32px 0 10px;padding-bottom:6px;border-bottom:2px solid var(--line)}h3{font-size:14px;margin:18px 0 8px;color:var(--sub)}
.meta{color:var(--sub);margin-bottom:12px}.status{display:inline-block;padding:4px 10px;border-radius:6px;font-weight:600;margin:6px 0}.status.draft{background:var(--draft)}.status.final{background:var(--final)}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:10px 0}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px}.kpi .v{font-size:22px;font-weight:700}.kpi .l{color:var(--sub);font-size:12px}.kpi .d{font-size:12px}
ul.head{margin:0;padding-left:18px}.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;background:var(--card);font-variant-numeric:tabular-nums}th,td{border:1px solid var(--line);padding:6px 8px;text-align:right;white-space:nowrap}th{background:var(--head);font-weight:600;text-align:center}td:first-child{text-align:left}tr.total td{font-weight:700;background:var(--head)}tr.share td{color:var(--sub);font-size:12px}
.up{color:var(--up)}.down{color:var(--down)}.neg{color:var(--up)}.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;color:#fff}.pill.ok{background:var(--ok)}.pill.mid{background:var(--mid)}.pill.low{background:var(--low)}
svg{width:100%;height:auto;max-width:640px}svg .grid{stroke:var(--line)}svg .ax,svg .lg{fill:var(--sub);font-size:11px}svg polyline{fill:none;stroke-width:2.5}.s0{stroke:var(--s0)}.s1{stroke:var(--s1)}.s2{stroke:var(--s2)}.s0f{fill:var(--s0)}.s1f{fill:var(--s1)}.s2f{fill:var(--s2)}
.kpis .card{margin:0}.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:10px}.note{color:var(--sub);font-size:12px}.lv-오류{color:var(--low);font-weight:700}.lv-경고{color:var(--mid);font-weight:700}
@media print{body{background:#fff}.card{break-inside:avoid}h2{break-after:avoid}}
'@

$hb = New-Object System.Text.StringBuilder
function B([string]$s) { [void]$hb.Append($s) }
B '<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
B ('<title>경영실적 보고 {0}</title><style>{1}</style></head><body><main>' -f (Esc $Month), $css)
B ('<h1>{0}년 {1}월 경영실적 보고</h1>' -f $Month.Substring(0, 4), $mm)
B ('<div class="meta">사업연도 FY{0} ({1} ~ {2}) · 보고 범위: {3} 당월 및 누계 · 단위: {4} · 순수주 = 수주금액 − 용역비 − 판매수수료 · 순매출 = 매출금액 − 외주비</div>' -f $FY, (Get-MStr $FYStartKey), (Get-MStr ($FYStartKey + 11)), $Month, (Esc $UnitLabel))
B ('<div class="status {0}">{1}</div> <span class="note">검증 오류 {2}건 · 경고 {3}건 · 생성 {4}</span>' -f $(if ($IsFinal) { 'final' } else { 'draft' }), (Esc $StatusText), $ErrCount, $WarnCount, (Esc $Now))
if ($CloseMessage) { B ('<div class="card">{0}</div>' -f (Esc $CloseMessage)) }

B '<h2>1. Executive Summary</h2><div class="kpis">'
$kp = @(@('순수주', 'month', ('{0}월 순수주' -f $mm)), @('순수주', 'ytd', '누계 순수주'), @('순매출', 'month', ('{0}월 순매출' -f $mm)), @('순매출', 'ytd', '누계 순매출'))
if ($ShowMetrics -contains '영업이익') { $kp += , @('영업이익', 'ytd', '누계 영업이익') }
foreach ($k in $kp) {
    $mets = if ($k[1] -eq 'month') { $MonthMetrics } else { $YtdMetrics }
    $d = Format-Diff $mets[0][$k[0]] $mets[1][$k[0]]
    $rt = if ($k[0] -eq '영업이익') { '' } else { ', ' + (Format-Rate $mets[0][$k[0]] $mets[1][$k[0]]) }
    $dc = if ($d -like '▲*') { 'up' } elseif ($d -like '▼*') { 'down' } else { '' }
    B ('<div class="card kpi"><div class="l">{0}</div><div class="v">{1}</div><div class="d {2}">전년 대비 {3}{4}</div></div>' -f (Esc $k[2]), (Esc (Format-Num $mets[0][$k[0]])), $dc, (Esc $d), (Esc $rt))
}
B '</div><div class="card"><ul class="head">'
foreach ($l in $Headline) { B ('<li>{0}</li>' -f (Esc $l)) }
B '</ul></div>'

function Add-MetricHtml([string]$Title, $Mets) {
    B ('<h2>{0}</h2><div class="scroll"><table><tr><th>지표</th><th>{1}</th><th>{2}</th><th>{3}</th><th>전년대비 증감액</th><th>증감률</th></tr>' -f (Esc $Title), $Periods[0].Label, $Periods[1].Label, $Periods[2].Label)
    foreach ($n in $ShowMetrics) {
        B ('<tr><td>{0}</td>{1}{2}{3}{4}{5}</tr>' -f (Esc $n), (Td (Format-Num $Mets[2][$n])), (Td (Format-Num $Mets[1][$n])), (Td (Format-Num $Mets[0][$n])), (Td (Format-Diff $Mets[0][$n] $Mets[1][$n])), (Td $(if ($n -eq '영업이익') { '-' } else { Format-Rate $Mets[0][$n] $Mets[1][$n] })))
    }
    B '</table></div>'
}
Add-MetricHtml ('2. 전사 당월 실적 ({0}월, 3개년)' -f $mm) $MonthMetrics
Add-MetricHtml ('3. 전사 누계 실적 ({0} ~ {1})' -f (Get-MStr $FYStartKey).Substring(2), $Month.Substring(2)) $YtdMetrics

B ('<h2>4. 목표 대비 (FY{0}, 경과 {1}/12개월 · 경과율 {2})</h2>' -f $FY, $FYIdx, (Format-Pct ($FYIdx / 12)))
if ($planShown) {
    B '<div class="scroll"><table><tr><th>지표</th><th>연간목표</th><th>누계실적</th><th>목표부족액</th><th>달성률</th><th>연환산 예상</th><th>예상 달성률</th></tr>'
    foreach ($r in $planRows) { B ('<tr><td>{0}</td>{1}{2}{3}{4}{5}{6}</tr>' -f (Esc $r.Name), (Td (Format-Num $r.Plan)), (Td (Format-Num $r.Act)), (Td (Format-Num $r.Gap)), (RateTd $r.Rate $Elapsed ($CostMetrics -contains $r.Name)), (Td (Format-Num $r.Fc)), (RateTd $r.FcRate 1 ($CostMetrics -contains $r.Name))) }
    B '</table></div><p class="note">연환산 예상 = 누계 ÷ 경과월 × 12 (계절성 미반영 단순 환산). 달성률 색은 경과율 대비 진도 기준(진도 100% 이상 초록 · 90~100% 주황 · 90% 미만 빨강, 비용 항목은 반대), 예상 달성률은 100% 기준</p>'
}
else { B '<p class="note">사업계획(전사) 데이터가 없어 생략했습니다.</p>' }

$sec = 5
foreach ($kind in @(@('orders', '순수주'), @('sales', '순매출'))) {
    B ('<h2>{0}. 제품군별 {1}</h2>' -f $sec, $kind[1])
    foreach ($pm in @(@('month', ('당월({0}월)' -f $mm)), @('ytd', '누계'))) {
        $tb = $GT[$kind[0] + '|' + $pm[0]]
        $withPlan = ($pm[0] -eq 'ytd')
        B ('<h3>{0} {1}</h3><div class="scroll"><table><tr><th>제품군</th><th>{2}</th><th>{3}</th><th>{4}</th><th>전년대비 증감액</th><th>증감률</th>{5}</tr>' -f (Esc $pm[1]), $kind[1], $Periods[0].Label, $Periods[1].Label, $Periods[2].Label, $(if ($withPlan) { '<th>연간목표</th><th>달성률</th>' } else { '' }))
        foreach ($r in $tb.Rows) {
            $extra = ''
            if ($withPlan) { $pl = Get-Plan $Plan $FY '제품군' $r.Group $kind[1]; $extra = (Td (Format-Num $pl)) + (RateTd $(if ($null -ne $pl -and $pl -ne 0) { $r.V[0] / $pl } else { $null }) $Elapsed) }
            B ('<tr><td>{0}</td>{1}{2}{3}{4}{5}{6}</tr>' -f (Esc $r.Group), (Td (Format-Num $r.V[2])), (Td (Format-Num $r.V[1])), (Td (Format-Num $r.V[0])), (Td (Format-Diff $r.V[0] $r.V[1])), (Td (Format-Rate $r.V[0] $r.V[1])), $extra)
        }
        $extra = ''
        if ($withPlan) { $pl = Get-Plan $Plan $FY '전사' '전사' $kind[1]; $extra = (Td (Format-Num $pl)) + (RateTd $(if ($null -ne $pl -and $pl -ne 0) { $tb.Total[0] / $pl } else { $null }) $Elapsed) }
        B ('<tr class="total"><td>TOTAL</td>{0}{1}{2}{3}{4}{5}</tr>' -f (Td (Format-Num $tb.Total[2])), (Td (Format-Num $tb.Total[1])), (Td (Format-Num $tb.Total[0])), (Td (Format-Diff $tb.Total[0] $tb.Total[1])), (Td (Format-Rate $tb.Total[0] $tb.Total[1])), $extra)
        $mt = @($tb.Rows | Where-Object { $_.Group -eq $MaintType })
        if ($mt.Count -gt 0) {
            $cells = ''
            foreach ($o in @(2, 1, 0)) { $cells += '<td>' + $(if ($null -ne $tb.Total[$o] -and $tb.Total[$o] -ne 0) { Format-Pct ($mt[0].V[$o] / $tb.Total[$o]) } else { '-' }) + '</td>' }
            B ('<tr class="share"><td>{0} 비중</td>{1}<td></td><td></td>{2}</tr>' -f (Esc $MaintType), $cells, $(if ($withPlan) { '<td></td><td></td>' } else { '' }))
        }
        B '</table></div>'
    }
    $sec++
}

B ('<h2>{0}. 부서별 누계 순수주</h2>' -f $sec)
if ($DeptRows.Count -gt 0) {
    B ('<div class="scroll"><table><tr><th>부서</th><th>누계 {0}</th><th>전년 동기 {1}</th><th>증감액</th><th>증감률</th><th>연간목표</th><th>달성률</th></tr>' -f $Periods[2].Label, $Periods[1].Label)
    foreach ($d in $DeptRows) { B ('<tr><td>{0}</td>{1}{2}{3}{4}{5}{6}</tr>' -f (Esc $d.Dept), (Td (Format-Num $d.Cur)), (Td (Format-Num $d.Py)), (Td (Format-Diff $d.Cur $d.Py)), (Td (Format-Rate $d.Cur $d.Py)), (Td (Format-Num $d.Plan)), (RateTd $(if ($null -ne $d.Plan -and $d.Plan -ne 0) { $d.Cur / $d.Plan } else { $null }) $Elapsed)) }
    B '</table></div>'
}
else { B '<p class="note">수주실적에 부서 열이 없어 생략했습니다.</p>' }
$sec++

B ('<h2>{0}. 인원·인당 생산성</h2>' -f $sec)
if ($People.Count -gt 0) {
    B '<div class="scroll"><table><tr><th>구분</th><th>평균인원(명)</th><th>인당 순수주</th><th>연환산</th><th>인당 순매출</th><th>연환산</th></tr>'
    foreach ($p in ($People | Sort-Object Off -Descending)) { B ('<tr><td>누계 {0}</td><td>{1}</td>{2}{3}{4}{5}</tr>' -f $p.Label, ([math]::Round($p.Avg, 1, [MidpointRounding]::AwayFromZero)).ToString('0.0', $Inv), (Td (Format-Num $p.OrdersPer)), (Td (Format-Num ($p.OrdersPer / $FYIdx * 12))), (Td (Format-Num $p.SalesPer)), (Td (Format-Num ($p.SalesPer / $FYIdx * 12)))) }
    B '</table></div><p class="note">평균인원 = 누계 기간 월말인원 평균. 연환산 = 인당 누계 ÷ 경과월 × 12</p>'
}
else { B '<p class="note">손익실적(월말인원)이 없어 생략했습니다.</p>' }
$sec++

B ('<h2>{0}. 월별 누적 추이</h2><div class="charts"><div class="card"><h3>누적 순수주</h3>{1}</div><div class="card"><h3>누적 순매출</h3>{2}</div></div>' -f $sec, (Get-TrendSvg 'CumOrders' '누적 순수주'), (Get-TrendSvg 'CumSales' '누적 순매출'))
$sec++

B ('<h2>{0}. 검증 결과</h2>' -f $sec)
if ($sortedIssues.Count -eq 0) { B '<p>오류·경고 없음</p>' }
else {
    B '<div class="scroll"><table><tr><th>수준</th><th>코드</th><th>파일</th><th>행</th><th>PJT코드</th><th>월</th><th>내용</th></tr>'
    foreach ($x in ($sortedIssues | Select-Object -First 50)) { B ('<tr><td class="lv-{0}">{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td style="text-align:left;white-space:normal">{6}</td></tr>' -f (Esc $x.Level), (Esc $x.Code), (Esc $x.File), (Esc ([string]$x.Line)), (Esc $x.Pjt), (Esc $x.Month), (Esc $x.Message)) }
    B '</table></div>'
}
B ('<p class="note">제품군 체계: {0}. 자동 생성 — Invoke-PerformanceReport.ps1</p>' -f $(if ($MappingBasis -eq 'transaction') { '거래월 기준' } else { "보고월($Month) 기준으로 과거 실적 재분류" }))
B '</main></body></html>'
Write-Text (Join-Path $Out '경영실적보고서.html') $hb.ToString()

if ($IsFinal) {
    $ver = $ClosedMap[$Month].Version
    $fin = Join-Path $Out '확정'
    if (-not (Test-Path $fin)) { New-Item -ItemType Directory -Path $fin -Force | Out-Null }
    Copy-Item (Join-Path $Out '경영실적보고서.html') (Join-Path $fin ('경영실적보고서_{0}_v{1}.html' -f ($Month -replace '-', ''), $ver)) -Force
    Copy-Item (Join-Path $Out '요약.md') (Join-Path $fin ('요약_{0}_v{1}.md' -f ($Month -replace '-', ''), $ver)) -Force
}

# ─────────────────────────────────────────────────────────────
# 17. 콘솔 요약
# ─────────────────────────────────────────────────────────────
Write-Host ('[{0}] {1}' -f $Month, $StatusText)
Write-Host ('검증: 오류 {0}건 · 경고 {1}건' -f $ErrCount, $WarnCount)
foreach ($l in $Headline) { Write-Host ('  - ' + $l) }
if ($CloseMessage) { Write-Host $CloseMessage }
Write-Host ('결과: {0}' -f $Out)
if ($CloseFailed) { exit 2 }
exit 0
