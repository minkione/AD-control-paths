#
# Script parameters & variables
# 
Param(
    [string]$outputDir = $null,
    [string]$logLevel = 'INFO',

    [string]$domainController = $null,
    [int]$ldapPort = $null,
    [string]$domainDnsName = $null,
    [string]$sysvolPath = $null,
    
    [string]$user = $null,
    [string]$password = $null,
    
    [switch]$useBackupPriv = $false,
    
    [switch]$ldapOnly = $false,
    [switch]$sysvolOnly = $false,
	
	  [switch]$fromExistingDumps = $false,
    
    [switch]$help = $false,
    [switch]$generateCmdOnly = $false
)

$globalTimer = $null
$globalLogFile = $null
$dumpLdap = $ldapOnly.IsPresent -or (!$ldapOnly.IsPresent -and !$sysvolOnly.IsPresent)
$dumpSysvol = $sysvolOnly.IsPresent -or (!$ldapOnly.IsPresent -and !$sysvolOnly.IsPresent)
$date =  date -Format yyyyMMdd

#
# Verifying script options
# 
Function Usage([string]$errmsg = $null)
{
    if($errmsg) {
        Write-Output "Error: $errmsg"
    }

    Write-Output "Usage: $(Split-Path -Leaf $PSCommandPath) [PARAMETERS]"
    
    Write-Output "- Required parameters:"
    Write-Output "`t-outputDir <DIR>                : output directory"
    Write-Output "`t-domainController <DC>          : ip/host of the DC to query"
    Write-Output "`t-domainDnsName <DNSNAME>        : dns name of the domain (ex: mydomain.local)"
    
    Write-Output "- Optional parameters:"
    Write-Output "`t-help                           : show this help"
    Write-Output "`t-sysvolPath <PATH>              : path of the 'Policies' folder of the sysvol"
    Write-Output "`t-user <USRNAME> -password <PWD> : username and password to use for explicit authentication"
    Write-Output "`t-logLevel <LVL>                 : log level, possibles values are ALL,DBG,INFO(default),WARN,ERR,SUCC,NONE"
    Write-Output "`t-ldapPort <PORTNUM>             : ldap port to use (default is 389)"
    
    Write-Output "`t-useBackupPriv                  : use backup privilege to access -sysvolPath"
    Write-Output "`t-ldapOnly                       : only dump data from the LDAP directory"
    Write-Output "`t-sysvolOnly                     : only dump data from the sysvol"
	Write-Output "`t-fromExistingDumps              : use previous directorycrawler dump files in target folder"
    Write-Output "`t-generateCmdOnly                : generate a list of commands to dump data, instead of executing them"

    Break
}

if($help -or ($args -gt 0)) {
    Usage
}
if(!$outputDir) {
    Usage "-outputDir parameter is required."
}
if(!$domainController) {
    Usage "-domainController parameter is required."
}
if(!$domainDnsName) {
    Usage "-domainDnsName parameter is required."
}
if([bool]$user -bXor [bool]$password) {
    Usage "-user and -password must both be specified to use explicit authentication"
}
if($ldapPort -lt 0) {
    Usage "-ldapPort must be > 0"
}
if($ldapOnly.IsPresent -and $sysvolOnly.IsPresent) {
    Usage "-ldapOnly and -sysvolOnly cannot be used at the same time"
}
if(!($sysvolPath) -and $dumpSysvol) {
    Usage "-sysvolPath parameter is required."
}

#
# Functions
#
Function Write-Output-And-Global-Log([string]$str)
{
    if(!$generateCmdOnly) {
        Write-Output $str
        Add-Content $globalLogFile "[$($globalTimer.Elapsed)] $str"
    }
}
 
Function Execute-Cmd-Wrapper([string]$cmd, [array]$optionalParams, [bool]$maxRetVal=0)
{
    Foreach ($param in $optionalParams) {
        if($param) {
            $val = $param[0]
            $str = $param[1]
            if( $val ) { # ! null/empty/whitespaces/false...
                $cmd += " $str"
            }
        }
    }
    $cmd = $cmd -replace '\s+', ' '
    $error = $null
    $timer = $null
    
    if($generateCmdOnly) {
        Write-Output $cmd
    } else {
        Try {
            Write-Output-And-Global-Log "********************"
            Write-Output-And-Global-Log "* Command: $cmd"
            Write-Output "*"
            $timer = [Diagnostics.Stopwatch]::StartNew()
            Invoke-Expression $cmd
            if(($LASTEXITCODE -lt 0) -or ($LASTEXITCODE -gt $maxRetVal)) {
                throw "return code is non-zero ($LASTEXITCODE)"
            }
        } Catch {
            $error = $_.Exception.Message
            Break
        } Finally {
            $timer.Stop()
            Write-Output "*"
            Write-Output-And-Global-Log "* Time   : $($timer.Elapsed)"
            if($error) {
                Write-Output-And-Global-Log "* Return : FAIL - $error"
            } else {
                Write-Output-And-Global-Log "* Return : OK - $LASTEXITCODE"
            }
            Write-Output-And-Global-Log "********************`n"
        }
    }
}

# 
# Creating output directories
#
#   $outputDir\
#     |- Ldap
#     |- Logs
#     \- Relations
#
$outputDirParent = $outputDir
$outputDir += "\$date`_$domainDnsName"
$directories = (
    "$outputDir",
	  "$outputDir\Ldap",
    "$outputDir\Logs",
    "$outputDir\Relations"
)
if (!$generateCmdOnly) {
    Foreach($dir in $directories) {
        if(!(Test-Path -Path $dir)) {
            New-Item -ItemType directory -Path $dir | Out-Null
# No native PS equivalent
			compact /C $dir | Out-Null
        }
    }
}

# 
# Start
# 
$globalLogFile = "$outputDir\logs\$filesPrefix.global.log"
If(Test-Path -Path $globalLogFile) {
    Clear-Content $globalLogFile
}
$globalTimer = [Diagnostics.Stopwatch]::StartNew()
Write-Output-And-Global-Log "[+] Starting"
if($user) {
    Write-Output-And-Global-Log "[+] Using explicit authentication with username '$user'"
} else {
    Write-Output-And-Global-Log "[+] Using implicit authentication"
}
if($ldapOnly.IsPresent) {
    Write-Output-And-Global-Log "[+] Dumping LDAP data only`n"
} elseif($sysvolOnly.IsPresent) {
    Write-Output-And-Global-Log "[+] Dumping SYSVOL data only`n"
} else {
    Write-Output-And-Global-Log "[+] Dumping LDAP and SYSVOL data`n"
}
if($fromExistingDumps.IsPresent) {
    Write-Output-And-Global-Log "[+] Working from existing dump files`n"
}

$filesPrefix = $domainDnsName.Substring(0,2).ToUpper()

# 
# LDAP data
# 
$optionalParams = (
    ($ldapPort,         "-n '$ldapPort'"),
    ($user,             "-l '$user' -p '$password'"),
    ($domainDnsName,    "-d '$domainDnsName'")
)

if($dumpLdap -and !$fromExistingDumps.IsPresent) {

# Dump
   Execute-Cmd-Wrapper -optionalParams $optionalParams -cmd @"
     .\Bin\directorycrawler.exe
   -w '$logLevel'
   -f '$outputDir\Logs\$filesPrefix.dircrwl.log'
   -j '.\Bin\ADng_ADCP.json'
   -o '$outputDirParent'
   -s '$domainController'
"@
}

if($dumpLdap) {

Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.Ad.Container.exe
    -D '$logLevel'
    -L '$outputDir\Logs\$filesPrefix.control.ad.container.log'
    -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    -O '$outputDir\Relations\$filesPrefix.control.ad.container.csv'
"@

Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.Ad.Gplink.exe
    -D '$logLevel'
    -L '$outputDir\Logs\$filesPrefix.control.ad.gplink.log'
	  -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    -O '$outputDir\Relations\$filesPrefix.control.ad.gplink.csv'
"@

Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.Ad.Group.exe
    -D '$logLevel'
    -L '$outputDir\Logs\$filesPrefix.control.ad.group.log'
    -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    -O '$outputDir\Relations\$filesPrefix.control.ad.group.csv'
"@

Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.Ad.Sd.exe
    -D '$logLevel'
    -L '$outputDir\logs\$filesPrefix.control.ad.sd.log'
	  -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
  	-A '$outputDir\Ldap\$($filesPrefix)_LDAP_ace.csv'
    -O '$outputDir\Relations\$filesPrefix.control.ad.sd.csv'
"@

Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.Ad.PrimaryGroup.exe
    -D '$logLevel'
    -L '$outputDir\Logs\$filesPrefix.control.ad.primarygroup.log'
	  -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    -O '$outputDir\Relations\$filesPrefix.control.ad.primarygroup.csv'
"@

Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.Ad.SidHistory.exe
    -D '$logLevel'
    -L '$outputDir\Logs\$filesPrefix.control.ad.sidhistory.log'
	  -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    -O '$outputDir\Relations\$filesPrefix.control.ad.sidhistory.csv'
"@

Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.Ad.Rodc.exe
    -D '$logLevel'
    -L '$outputDir\Logs\$filesPrefix.control.ad.sidhistory.log'
	  -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    -O '$outputDir\Relations\$filesPrefix.control.ad.rodc.csv'
    -Y '$outputDir\Relations\$filesPrefix.control.ad.rodc.deny.csv'
"@

# Filter
Execute-Cmd-Wrapper -cmd @"
.\Bin\AceFilter.exe
    --loglvl='$logLevel'
    --logfile='$outputDir\Logs\$filesPrefix.acefilter.ldap.msr.log'
    --importer='LdapDump'
    --writer='MasterSlaveRelation'
    --filters='Inherited,ObjectType,ControlAd'
    --
    msrout='$outputDir\Relations\$filesPrefix.acefilter.ldap.msr.csv'
    ldpobj='$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    ldpsch='$outputDir\Ldap\$($filesPrefix)_LDAP_sch.csv'
    ldpace='$outputDir\Ldap\$($filesPrefix)_LDAP_ace.csv'
"@

}

# 
# SYSVOL data
# 
if($dumpSysvol) {

# GPO Owners
$optionalParams += , ($useBackupPriv, "-B")
Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.Sysvol.Sd.exe
    -D '$logLevel'
    -L '$outputDir\Logs\$filesPrefix.control.sysvol.sd.log'
	  -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    -O '$outputDir\Relations\$filesPrefix.control.sysvol.sd.csv'
    -S '$sysvolPath'
"@

# GPO files ACE filtering
$optionalParams = (,($useBackupPriv, "usebackpriv=1"))
Execute-Cmd-Wrapper -cmd @"
.\Bin\AceFilter.exe
    --loglvl='$logLevel'
    --logfile='$outputDir\logs\$filesPrefix.acefilter.sysvol.msr.log'
    --importers='Sysvol,LdapDump'
    --writer='MasterSlaveRelation'
    --filters='Inherited,ControlFs'
    --
    msrout='$outputDir\Relations\$filesPrefix.acefilter.sysvol.msr.csv'
    ldpobj='$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
    ldpsch='$outputDir\Ldap\$($filesPrefix)_LDAP_sch.csv'
    sysvol='$sysvolPath'
"@

}

#
# Make all nodes from LDAP and relations
#
Execute-Cmd-Wrapper -cmd @"
.\Bin\Control.MakeAllNodes.exe
    -D '$logLevel'
    -L '$outputDir\Logs\$filesPrefix.convert.ad.lowercase.log'
    -I '$outputDir\Ldap\$($filesPrefix)_LDAP_obj.csv'
	  -A '$((dir $outputDir\Relations\*.csv -exclude *.deny.csv) -join ',')'
    -O '$outputDir\Ldap\all_nodes.csv'
    -s '$domainController'
"@


# 
# End
# 
$globalTimer.Stop()
Write-Output-And-Global-Log "[+] Done. Total time: $($globalTimer.Elapsed)`n"
