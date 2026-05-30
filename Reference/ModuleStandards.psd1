<#
===============================================================================
 MODULE CODING STANDARDS
===============================================================================

This module follows a strict and consistent PowerShell function design standard.
All functions implemented in this module MUST comply with the rules below.

FUNCTION DESIGN RULES
---------------------
1. Function names MUST use PowerShell approved verbs only.
2. All functions MUST be advanced functions using the CmdletBinding attribute.
3. Parameters MUST be explicitly defined with appropriate types and attributes.
4. Error handling MUST be implemented using try / catch / finally blocks.
5. Write-Host MUST be used for logging, tracing, and diagnostics.
6. $null comparisons MUST use -eq or -ne operators, with $null on the LEFT side.
7. $MyInvocation.MyCommand.Name MUST be used for all logging and tracing messages.
8. All parameter values received by the function MUST be logged using Write-Host.

ERROR HANDLING STANDARD
-----------------------
- Functions MUST preserve the original exception.
- When adding context, exceptions MUST be wrapped using InnerException.
- Throwing string-based errors is NOT allowed.

LOGGING STANDARD
----------------
- Each function MUST log:
  - START of execution
  - Parameters received
  - Key execution steps
  - Result or outcome
  - END of execution
- Log messages MUST follow this format:
  <FunctionName>:: <message>

===============================================================================
#>

function Get-SampleFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SampleStringParam = "DefaultValue",

        [Parameter(Mandatory = $false)]
        [int]$SampleIntParam,

        [Parameter(Mandatory = $false)]
        [string]$AnotherStringParam,

        [Parameter(Mandatory = $false)]
        [switch]$SampleSwitchParam
    )

    Write-Host "$($MyInvocation.MyCommand.Name):: START"

    try {
        $result = $null

        Write-Host "$($MyInvocation.MyCommand.Name):: Parameters received:"
        Write-Host "$($MyInvocation.MyCommand.Name):: SampleStringParam    : $SampleStringParam"
        Write-Host "$($MyInvocation.MyCommand.Name):: SampleIntParam       : $SampleIntParam"
        Write-Host "$($MyInvocation.MyCommand.Name):: AnotherStringParam   : $AnotherStringParam"
        Write-Host "$($MyInvocation.MyCommand.Name):: SampleSwitchParam    : $SampleSwitchParam"

        #
        # Main logic
        #
        if ($SampleSwitchParam) {
            Write-Host "$($MyInvocation.MyCommand.Name):: SampleSwitchParam is enabled"
            $result = $SampleStringParam.ToUpper()
        }
        else {
            Write-Host "$($MyInvocation.MyCommand.Name):: SampleSwitchParam is disabled"
            $result = $SampleStringParam.ToLower()
        }

        if ($SampleIntParam -gt 0) {
            Write-Host "$($MyInvocation.MyCommand.Name):: SampleIntParam is greater than zero"
            $result += " - Number: $SampleIntParam"
        }
        else {
            Write-Host "$($MyInvocation.MyCommand.Name):: SampleIntParam is not greater than zero"
        }

        if ($null -ne $AnotherStringParam) {
            Write-Host "$($MyInvocation.MyCommand.Name):: AnotherStringParam is provided"
            $result += " - Another: $AnotherStringParam"
        }
        else {
            Write-Host "$($MyInvocation.MyCommand.Name):: AnotherStringParam is not provided"
        }

        Write-Host "$($MyInvocation.MyCommand.Name):: Result: $result"
        return $result
    }
    catch {
        $contextMessage = "$($MyInvocation.MyCommand.Name):: Failed to process sample function"
        Write-Host "$($MyInvocation.MyCommand.Name):: ERROR: $($_.Exception.Message)"
        throw [System.Exception]::new($contextMessage, $_.Exception)
    }
    finally {
        Write-Host "$($MyInvocation.MyCommand.Name):: END"
    }
}
