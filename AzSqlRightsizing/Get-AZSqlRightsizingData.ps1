<#
.SYNOPSIS
    Azure SQL Database and Elastic Pool Cost & Performance Analysis

.DESCRIPTION
    Analyzes Azure SQL Database and Elastic Pool costs, performance metrics, and provides 
    right-sizing recommendations across multiple Azure subscriptions.
    
    Features:
    - Multi-subscription support
    - Actual monthly costs from Azure Cost Management API
    - 30-day performance metrics (DTU/vCore utilization)
    - Smart right-sizing recommendations (80% target utilization)
    - Tier change opportunity detection
    - Unused database identification
    - Comprehensive CSV export

.PARAMETER IncludeScaleUpRecommendations
    Include over-utilized resources needing more capacity in the report.
    Default: $false (focuses on cost-saving opportunities only)

.OUTPUTS
    AzSqlRightsizingReport-YYYY-MM-DD-HHmm.csv

.EXAMPLE
    .\Get-AZSqlRightsizingData.ps1
    Analyzes all enabled subscriptions and exports cost-saving recommendations

.EXAMPLE
    # Include scale-up recommendations
    $IncludeScaleUpRecommendations = $true
    .\Get-AZSqlRightsizingData.ps1

.NOTES
    Requires: Az.Accounts, Az.Sql, Az.Monitor, Az.Resources modules
    RBAC Roles: Reader, Cost Management Reader, Monitoring Reader
    Author: Azure SQL Cost Optimization
    Version: 1.4
#>

# Login & set context
#Connect-AzAccount -UseDeviceAuthentication

# Configure which subscriptions to include (or query all)
#$subscriptions = (Get-AzSubscription | Where-Object { $_.State -eq "Enabled" -and $_.Name -eq "XYZ" })  # Limit to specific subscription

#$subscriptions = (Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }) | Select-Object -First 1  # Test with first subscription
$subscriptions = (Get-AzSubscription | Where-Object { $_.State -eq "Enabled" })  # full run

# Include scale-up recommendations in the report
# Set to $true to include resources that need more capacity (over-utilized)
# Set to $false (default) to focus only on cost-saving opportunities
$IncludeScaleUpRecommendations = $false

# API rate limiting configuration
# Cost Management API has strict rate limits. Delay helps avoid 429 errors.
# Adjust this value based on the number of resources and API response times.
$apiDelayMs = 500  # milliseconds between API calls

#$subscriptions.count

# Time range for "last 30 days"
$endTime   = (Get-Date).ToUniversalTime()
$startTime = $endTime.AddDays(-30)

# Helper: Calculate right-sizing recommendation
function Get-RightSizingRecommendation {
    param(
        [string]$ServiceTier,
        [int]$CurrentCapacity,
        $AvgMaxUtilPercent,  # Can be $null, 0, or a positive number
        [decimal]$CurrentCost,
        [string]$DtuOrVCore
    )
    
    # If no utilization data available (null), can't make recommendation
    if ($null -eq $AvgMaxUtilPercent) {
        return @{
            RecommendedCapacity = $CurrentCapacity
            RecommendedAction = "NoMetrics"
            EstimatedCost = $CurrentCost
            PotentialSavings = 0
            TierChangeOpportunity = ""
            TierChangeSavings = 0
        }
    }
    
    # If 0% utilization, database is unused - recommend minimum tier
    if ($AvgMaxUtilPercent -eq 0) {
        # Define minimum tiers
        $minDtuTiers = @{
            "Basic" = 5
            "Standard" = 10
            "Premium" = 125
        }
        $minVCore = 1
        
        $recommendedCapacity = $CurrentCapacity
        if ($DtuOrVCore -eq "DTU" -and $minDtuTiers.ContainsKey($ServiceTier)) {
            $recommendedCapacity = $minDtuTiers[$ServiceTier]
        } elseif ($DtuOrVCore -eq "vCore") {
            $recommendedCapacity = $minVCore
        }
        
        # Calculate estimated cost at minimum tier
        $estimatedCost = if ($CurrentCapacity -gt 0) {
            [Math]::Round(($CurrentCost * $recommendedCapacity) / $CurrentCapacity, 2)
        } else {
            $CurrentCost
        }
        
        $potentialSavings = [Math]::Round($CurrentCost - $estimatedCost, 2)
        
        return @{
            RecommendedCapacity = $recommendedCapacity
            RecommendedAction = if ($recommendedCapacity -lt $CurrentCapacity) { "ScaleDown-Unused" } else { "Unused" }
            EstimatedCost = $estimatedCost
            PotentialSavings = $potentialSavings
            TierChangeOpportunity = ""
            TierChangeSavings = 0
        }
    }
    
    # Calculate needed capacity based on 80% target utilization
    # (leaving 20% headroom for spikes)
    $targetUtilization = 80
    $neededCapacity = [Math]::Ceiling(($CurrentCapacity * $AvgMaxUtilPercent) / $targetUtilization)
    
    # If current utilization is already below target (under-utilized), 
    # we might be able to scale down but should not scale up
    $isUnderUtilized = $AvgMaxUtilPercent -lt $targetUtilization
    
    # Define available tiers for DTU
    $dtuTiers = @{
        "Basic" = @(5)
        "Standard" = @(10, 20, 50, 100, 200, 400, 800, 1600, 3000)
        "Premium" = @(125, 250, 500, 1000, 1750, 4000)
    }
    
    # Define available vCore counts (includes 1 for serverless)
    $vCoreTiers = @(1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80)
    
    $recommendedCapacity = $CurrentCapacity
    
    if ($DtuOrVCore -eq "DTU" -and $dtuTiers.ContainsKey($ServiceTier)) {
        # Find the smallest tier that meets the need
        $availableTiers = $dtuTiers[$ServiceTier] | Where-Object { $_ -ge $neededCapacity } | Sort-Object
        if ($availableTiers -and $availableTiers.Count -gt 0) {
            $recommendedCapacity = $availableTiers[0]
        } else {
            # If needed capacity exceeds all tiers, recommend the highest
            $recommendedCapacity = ($dtuTiers[$ServiceTier] | Sort-Object -Descending)[0]
        }
        
        # If already under-utilized, don't scale up past current capacity
        if ($isUnderUtilized -and $recommendedCapacity -gt $CurrentCapacity) {
            $recommendedCapacity = $CurrentCapacity
        }
        
    } elseif ($DtuOrVCore -eq "vCore") {
        # Find the smallest vCore count that meets the need
        $availableTiers = $vCoreTiers | Where-Object { $_ -ge $neededCapacity } | Sort-Object
        if ($availableTiers -and $availableTiers.Count -gt 0) {
            $recommendedCapacity = $availableTiers[0]
        } else {
            $recommendedCapacity = ($vCoreTiers | Sort-Object -Descending)[0]
        }
        
        # If already under-utilized, don't scale up past current capacity
        if ($isUnderUtilized -and $recommendedCapacity -gt $CurrentCapacity) {
            $recommendedCapacity = $CurrentCapacity
        }
    }
    
    # Estimate cost based on linear scaling (rough approximation)
    $estimatedCost = if ($CurrentCapacity -gt 0) {
        [Math]::Round(($CurrentCost * $recommendedCapacity) / $CurrentCapacity, 2)
    } else {
        $CurrentCost
    }
    
    $potentialSavings = [Math]::Round($CurrentCost - $estimatedCost, 2)
    
    # Determine action
    $action = if ($recommendedCapacity -lt $CurrentCapacity) {
        "ScaleDown"
    } elseif ($recommendedCapacity -gt $CurrentCapacity) {
        "ScaleUp"
    } else {
        "NoChange"
    }
    
    # Check for tier change opportunities
    # If at minimum capacity with low utilization, suggest tier downgrade
    $tierChangeOpportunity = ""
    $tierSavingsEstimate = 0
    
    if ($action -eq "NoChange" -and $AvgMaxUtilPercent -lt 20) {
        # Define minimum capacities for each tier
        $minCapacities = @{
            "Basic_DTU" = 5
            "Standard_DTU" = 10
            "Premium_DTU" = 125
            "vCore" = 1
        }
        
        # Approximate cost ratios (relative to Basic 5 DTU = 1x)
        $tierCostRatios = @{
            "Basic_5" = 1.0      # ~27-30 DKK
            "Standard_10" = 2.8  # ~82-83 DKK
            "Premium_125" = 13.5 # ~400+ DKK
        }
        
        # Check if at minimum capacity for current tier
        $isAtMinimum = $false
        
        if ($DtuOrVCore -eq "DTU") {
            if ($ServiceTier -eq "Basic" -and $CurrentCapacity -eq 5) {
                $isAtMinimum = $true
            } elseif ($ServiceTier -eq "Standard" -and $CurrentCapacity -eq 10) {
                $isAtMinimum = $true
                $tierChangeOpportunity = "Consider Basic (5 DTU)"
                # Estimate: Basic is ~1/3 the cost of Standard
                $tierSavingsEstimate = [Math]::Round($CurrentCost * 0.65, 2)
            } elseif ($ServiceTier -eq "Premium" -and $CurrentCapacity -eq 125) {
                $isAtMinimum = $true
                $tierChangeOpportunity = "Consider Standard (10 DTU)"
                # Estimate: Standard 10 is much cheaper than Premium 125
                $tierSavingsEstimate = [Math]::Round($CurrentCost * 0.8, 2)
            }
        } elseif ($DtuOrVCore -eq "vCore" -and $CurrentCapacity -eq 1) {
            $isAtMinimum = $true
            # vCore pricing varies widely (serverless vs provisioned)
            # Only suggest if cost is significantly higher than Basic/Standard DTU
            if ($CurrentCost -gt 100) {
                $tierChangeOpportunity = "Consider DTU tier (Basic or Standard)"
                # Estimate: Could save 50-90% depending on current config
                $tierSavingsEstimate = [Math]::Round($CurrentCost * 0.70, 2)
            }
        }
    }
    
    return @{
        RecommendedCapacity = $recommendedCapacity
        RecommendedAction = $action
        EstimatedCost = $estimatedCost
        PotentialSavings = $potentialSavings
        TierChangeOpportunity = $tierChangeOpportunity
        TierChangeSavings = $tierSavingsEstimate
    }
}

# Helper: Get average metric for an elastic pool
function Get-PoolAvgMetric {
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [datetime]$StartTime,
        [datetime]$EndTime
    )
    $metricDef = Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName -TimeGrain (New-TimeSpan -Days 1) -StartTime $StartTime -EndTime $EndTime -Aggregation Average -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $metricDef) { return $null }
    $vals = $metricDef.Data | Where-Object { $_.Average -ne $null } | Select-Object -ExpandProperty Average
    if ($vals -and $vals.Count -gt 0) { return [math]::Round(($vals | Measure-Object -Average).Average, 2) } else { return $null }
}

# Helper: Get average of max metric values for an elastic pool
function Get-PoolAvgMaxMetric {
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [datetime]$StartTime,
        [datetime]$EndTime
    )
    $metricDef = Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName -TimeGrain (New-TimeSpan -Days 1) -StartTime $StartTime -EndTime $EndTime -Aggregation Maximum -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $metricDef) { return $null }
    $vals = $metricDef.Data | Where-Object { $_.Maximum -ne $null } | Select-Object -ExpandProperty Maximum
    if ($vals -and $vals.Count -gt 0) { return [math]::Round(($vals | Measure-Object -Average).Average, 2) } else { return $null }
}

# Helper: Invoke API with retry logic for rate limiting
function Invoke-AzRestMethodWithRetry {
    param(
        [string]$Method,
        [string]$Path,
        [string]$Payload,
        [int]$MaxRetries = 5
    )
    
    $retryCount = 0
    $baseDelay = 2
    
    while ($retryCount -lt $MaxRetries) {
        try {
            $result = Invoke-AzRestMethod -Method $Method -Path $Path -Payload $Payload
            
            if ($result.StatusCode -eq 429) {
                $retryCount++
                $delay = $baseDelay * [Math]::Pow(2, $retryCount - 1)
                
                # Check for Retry-After header
                $retryAfter = $result.Headers['Retry-After']
                if ($retryAfter) {
                    $delay = [int]$retryAfter
                }
                
                if ($retryCount -lt $MaxRetries) {
                    Write-Warning "Rate limit hit (429). Waiting $delay seconds before retry $retryCount/$MaxRetries..."
                    Start-Sleep -Seconds $delay
                    continue
                } else {
                    Write-Warning "Max retries reached for rate limiting"
                    return $result
                }
            }
            
            return $result
        } catch {
            Write-Warning "API call exception: $($_.Exception.Message)"
            throw
        }
    }
}

# Helper: Get all cost data for specific resource groups (query once per RG, use many times)
function Get-ResourceGroupsCostData {
    param(
        [string]$SubscriptionId,
        [array]$ResourceGroupNames
    )
    
    Write-Host "  Querying cost data for $($ResourceGroupNames.Count) resource group(s)..."
    
    # Calculate last month's date range
    $firstDayLastMonth = (Get-Date -Day 1).AddMonths(-1)
    $lastDayLastMonth = (Get-Date -Day 1).AddDays(-1)
    
    $allCostData = @{}
    
    foreach ($rgName in $ResourceGroupNames) {
        Write-Host "    Querying resource group: $rgName"
        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rgName"
        
        $dataset = @{
            granularity = "Monthly"
            grouping = @(
                @{ type = "Dimension"; name = "ResourceId" },
                @{ type = "Dimension"; name = "ResourceType" }
            )
            aggregation = @{
                totalCost = @{ name = "Cost"; function = "Sum" }
            }
        }
        
        # Query with Custom timeframe for complete previous month
        $body = @{
            type = "ActualCost"
            timeframe = "Custom"
            timePeriod = @{
                from = $firstDayLastMonth.ToString("yyyy-MM-ddT00:00:00Z")
                to = $lastDayLastMonth.ToString("yyyy-MM-ddT23:59:59Z")
            }
            dataset = $dataset
        } | ConvertTo-Json -Depth 10

        try {
            $allRows = @()
            $requestPath = "$scope/providers/Microsoft.CostManagement/query?api-version=2025-03-01"
            $skipToken = $null
            $pageCount = 0
            
            do {
                $pageCount++
                
                # Add skiptoken to path if we're paginating
                $currentPath = if ($skipToken) {
                    "$requestPath&`$skiptoken=$skipToken"
                } else {
                    $requestPath
                }
                
                if ($pageCount -gt 1) {
                    Write-Host "      Fetching page $pageCount..."
                }
                
                $result = Invoke-AzRestMethodWithRetry -Method POST -Path $currentPath -Payload $body
                
                if ($result.StatusCode -ne 200) {
                    Write-Warning "Cost query failed for RG $rgName : StatusCode $($result.StatusCode)"
                    break
                }
                
                $json = $result.Content | ConvertFrom-Json
                $rows = $json.properties.rows
                $allRows += $rows
                
                # Check for nextLink/skiptoken for pagination
                $skipToken = $null
                if ($json.properties.nextLink) {
                    # Extract skiptoken from nextLink
                    if ($json.properties.nextLink -match '\$skiptoken=([^&]+)') {
                        $skipToken = $matches[1]
                    }
                }
                
            } while ($skipToken)
            
            Write-Host "      Retrieved $($allRows.Count) cost records"
            
            # Build hashtable indexed by lowercase ResourceId
            # With Monthly granularity + ResourceType: Column 0=Cost, 1=BillingMonth, 2=ResourceId, 3=ResourceType, 4=Currency
            foreach ($row in $allRows) {
                $resourceIdLower = $row[2].ToLower()
                $allCostData[$resourceIdLower] = @{
                    Cost = [decimal]::Round([decimal]$row[0], 2)
                    Currency = $row[4]
                    Period = $firstDayLastMonth.ToString("MMM yyyy")
                }
            }
            
        } catch {
            Write-Warning "Cost query exception for RG $rgName : $($_.Exception.Message)"
        }
    }
    
    Write-Host "    Total unique resources with cost data: $($allCostData.Count)"
    return $allCostData
}

# Helper: Lookup cost for a specific resource from cached cost data
function Get-ResourceCostFromCache {
    param(
        [hashtable]$CostCache,
        [string]$ResourceId
    )
    
    $resourceIdLower = $ResourceId.ToLower()
    
    if ($CostCache.ContainsKey($resourceIdLower)) {
        $costInfo = $CostCache[$resourceIdLower]
        Write-Host "      Last month ($($costInfo.Period)) cost: $($costInfo.Cost) $($costInfo.Currency)"
        return $costInfo
    } else {
        Write-Host "      No cost data found for this resource in last month"
        # Try to get currency from any entry in cache
        $anyCurrency = if ($CostCache.Count -gt 0) { ($CostCache.Values | Select-Object -First 1).Currency } else { "" }
        return @{ Cost = 0; Currency = $anyCurrency; Period = "No data" }
    }
}

# Legacy function - kept for compatibility but replaced with cache-based approach
function Get-ResourceCost {
    param(
        [string]$SubscriptionId,
        [string]$ResourceId,
        [string]$ServerName,
        [string]$ResourceGroupName,
        [datetime]$StartTime,
        [datetime]$EndTime
    )
    # Query at subscription level with grouping by ResourceId
    $scope = "/subscriptions/$SubscriptionId"
    
    # Calculate last month's date range
    $now = Get-Date
    $firstDayLastMonth = (Get-Date -Day 1).AddMonths(-1)
    $lastDayLastMonth = (Get-Date -Day 1).AddDays(-1)
    
    $dataset = @{
        granularity = "Monthly"
        grouping = @(
            @{ type = "Dimension"; name = "ResourceId" }
        )
        aggregation = @{
            totalCost = @{ name = "Cost"; function = "Sum" }
        }
    }
    
    # Query with Custom timeframe for complete previous month
    $body = @{
        type = "ActualCost"
        timeframe = "Custom"
        timePeriod = @{
            from = $firstDayLastMonth.ToString("yyyy-MM-ddT00:00:00Z")
            to = $lastDayLastMonth.ToString("yyyy-MM-ddT23:59:59Z")
        }
        dataset = $dataset
    } | ConvertTo-Json -Depth 10

    try {
        $result = Invoke-AzRestMethodWithRetry -Method POST -Path "$scope/providers/Microsoft.CostManagement/query?api-version=2025-03-01" -Payload $body
        
        if ($result.StatusCode -ne 200) {
            Write-Warning "Cost query failed: StatusCode $($result.StatusCode)"
            return @{ Cost = 0; Currency = ""; Period = "Unknown" }
        }
        
        $json = $result.Content | ConvertFrom-Json
        $rows = $json.properties.rows
        
        # Cost Management returns lowercase ResourceIds
        $resourceIdLower = $ResourceId.ToLower()
        
        # Find the row matching our elastic pool resource ID
        # With Monthly granularity: Column 0=Cost, 1=BillingMonth, 2=ResourceId, 3=Currency
        $matchingRow = $rows | Where-Object { $_[2] -eq $resourceIdLower }
        
        if ($matchingRow) {
            $cost = [decimal]::Round([decimal]$matchingRow[0], 2)
            $currency = $matchingRow[3]
            $lastMonthName = $firstDayLastMonth.ToString("MMM yyyy")
            Write-Host "      Last month ($lastMonthName) cost: $cost $currency"
            return @{ Cost = $cost; Currency = $currency; Period = $lastMonthName }
        } else {
            Write-Host "      No cost data found for this resource in last month"
            # Try to get currency from any row in the result set (column 3 for Monthly granularity)
            $anyCurrency = if ($rows.Count -gt 0) { $rows[0][3] } else { "" }
            return @{ Cost = 0; Currency = $anyCurrency; Period = "No data" }
        }
    } catch {
        Write-Warning "Cost query exception: $($_.Exception.Message)"
        return @{ Cost = 0; Currency = ""; Period = "Error" }
    }
}

$report = @()

# Progress tracking
$totalSubscriptions = $subscriptions.Count
$currentSubscription = 0
$scriptStartTime = Get-Date

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Azure SQL Cost & Performance Analysis" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total subscriptions to process: $totalSubscriptions" -ForegroundColor Yellow
Write-Host "Start time: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow
Write-Host ""

foreach ($sub in $subscriptions) {
    $currentSubscription++
    
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "[$currentSubscription/$totalSubscriptions] Processing subscription: $($sub.Name)" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Get all SQL servers first
    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
    if (-not $servers) { 
        Write-Host "  No SQL servers found in subscription $($sub.Name)"
        continue 
    }

    # Get unique resource groups that contain SQL servers
    $resourceGroups = $servers | Select-Object -ExpandProperty ResourceGroupName -Unique
    Write-Host "  Found SQL servers in $($resourceGroups.Count) resource group(s)"

    # Get cost data for only the resource groups that contain SQL servers
    $costCache = Get-ResourceGroupsCostData -SubscriptionId $sub.Id -ResourceGroupNames $resourceGroups

    # Get elastic pools from each server
    $pools = @()
    foreach ($server in $servers) {
        $serverPools = Get-AzSqlElasticPool -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName -ErrorAction SilentlyContinue
        if ($serverPools) {
            $pools += $serverPools
        }
    }
    
    Write-Host "  Found $($pools.Count) elastic pool(s)"

    # Process Elastic Pools
    foreach ($pool in $pools) {
        Write-Host "    Analyzing pool: $($pool.ElasticPoolName) on $($pool.ServerName)"
        $poolResId = $pool.ResourceId  # /subscriptions/.../resourceGroups/.../providers/Microsoft.Sql/servers/{server}/elasticPools/{pool}

        # Determine if DTU or vCore based on Edition/ComputeModel
        # Simplified heuristic:
        $isDtu = $pool.Edition -in @("Basic","Standard","Premium")

        if ($isDtu) {
            $avgUtil = Get-PoolAvgMetric -ResourceId $poolResId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime
            $avgMaxUtil = Get-PoolAvgMaxMetric -ResourceId $poolResId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime
        } else {
            # vCore — take CPU as the primary utilization proxy; you can also compute a blended index
            $avgCpu   = Get-PoolAvgMetric -ResourceId $poolResId -MetricName "cpu_percent" -StartTime $startTime -EndTime $endTime
            $avgMaxCpu = Get-PoolAvgMaxMetric -ResourceId $poolResId -MetricName "cpu_percent" -StartTime $startTime -EndTime $endTime
            $avgData  = Get-PoolAvgMetric -ResourceId $poolResId -MetricName "data_io_percent" -StartTime $startTime -EndTime $endTime
            $avgLog   = Get-PoolAvgMetric -ResourceId $poolResId -MetricName "log_write_percent" -StartTime $startTime -EndTime $endTime
            # Choose CPU as headline; keep others for reference
            $avgUtil = $avgCpu
            $avgMaxUtil = $avgMaxCpu
        }

        $costResult = Get-ResourceCostFromCache -CostCache $costCache -ResourceId $poolResId

        # Get database count in this elastic pool
        $databases = Get-AzSqlDatabase -ServerName $pool.ServerName -ResourceGroupName $pool.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.ElasticPoolName -eq $pool.ElasticPoolName }
        $dbCount = if ($databases) { @($databases).Count } else { 0 }

        # Get right-sizing recommendation
        $rightSizing = Get-RightSizingRecommendation `
            -ServiceTier $pool.Edition `
            -CurrentCapacity $pool.Capacity `
            -AvgMaxUtilPercent $avgMaxUtil `
            -CurrentCost $costResult.Cost `
            -DtuOrVCore $(if ($isDtu) { "DTU" } else { "vCore" })

        $report += [pscustomobject]@{
            SubscriptionId   = $sub.Id
            SubscriptionName = $sub.Name
            ResourceGroup    = $pool.ResourceGroupName
            ServerName       = $pool.ServerName
            ResourceType     = "ElasticPool"
            ResourceName     = $pool.ElasticPoolName
            PoolName         = $pool.ElasticPoolName
            DatabaseCount    = $dbCount
            ServiceTier      = $pool.Edition
            SkuName          = $pool.SkuName
            Capacity         = $pool.Capacity
            ComputeModel     = $pool.ComputeModel
            DtuOrVCore       = if ($isDtu) { "DTU" } else { "vCore" }
            AvgUtilPercent   = $avgUtil
            AvgOfDailyMaxUtilPercent = $avgMaxUtil
            CostAmount       = $costResult.Cost
            Currency         = $costResult.Currency
            CostPeriod       = $costResult.Period
            RecommendedCapacity = $rightSizing.RecommendedCapacity
            RightSizingAction = $rightSizing.RecommendedAction
            EstimatedNewCost = $rightSizing.EstimatedCost
            PotentialSavings = $rightSizing.PotentialSavings
            TierChangeOpportunity = $rightSizing.TierChangeOpportunity
            TierChangeSavings = $rightSizing.TierChangeSavings
            ResourceId       = $poolResId
        }
    }

    # Process Standalone Databases (not in elastic pools)
    Write-Host "  Processing standalone databases..."
    $standaloneDatabases = @()
    foreach ($server in $servers) {
        $allDatabases = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName -ErrorAction SilentlyContinue
        $standalone = $allDatabases | Where-Object { 
            -not $_.ElasticPoolName -and 
            $_.DatabaseName -ne "master"  # Exclude system databases
        }
        if ($standalone) {
            $standaloneDatabases += $standalone
        }
    }
    
    Write-Host "  Found $($standaloneDatabases.Count) standalone database(s)"

    foreach ($db in $standaloneDatabases) {
        Write-Host "    Analyzing database: $($db.DatabaseName) on $($db.ServerName)"
        $dbResId = $db.ResourceId

        # Determine if DTU or vCore based on Edition/ComputeModel
        $isDtu = $db.Edition -in @("Basic","Standard","Premium")

        if ($isDtu) {
            $avgUtil = Get-PoolAvgMetric -ResourceId $dbResId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime
            $avgMaxUtil = Get-PoolAvgMaxMetric -ResourceId $dbResId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime
        } else {
            # vCore — take CPU as the primary utilization proxy
            $avgCpu   = Get-PoolAvgMetric -ResourceId $dbResId -MetricName "cpu_percent" -StartTime $startTime -EndTime $endTime
            $avgMaxCpu = Get-PoolAvgMaxMetric -ResourceId $dbResId -MetricName "cpu_percent" -StartTime $startTime -EndTime $endTime
            $avgUtil = $avgCpu
            $avgMaxUtil = $avgMaxCpu
        }

        $costResult = Get-ResourceCostFromCache -CostCache $costCache -ResourceId $dbResId

        # Get right-sizing recommendation
        $rightSizing = Get-RightSizingRecommendation `
            -ServiceTier $db.Edition `
            -CurrentCapacity $db.Capacity `
            -AvgMaxUtilPercent $avgMaxUtil `
            -CurrentCost $costResult.Cost `
            -DtuOrVCore $(if ($isDtu) { "DTU" } else { "vCore" })

        $report += [pscustomobject]@{
            SubscriptionId   = $sub.Id
            SubscriptionName = $sub.Name
            ResourceGroup    = $db.ResourceGroupName
            ServerName       = $db.ServerName
            ResourceType     = "Database"
            ResourceName     = $db.DatabaseName
            PoolName         = ""
            DatabaseCount    = 1
            ServiceTier      = $db.Edition
            SkuName          = $db.SkuName
            Capacity         = $db.Capacity
            ComputeModel     = $db.ComputeModel
            DtuOrVCore       = if ($isDtu) { "DTU" } else { "vCore" }
            AvgUtilPercent   = $avgUtil
            AvgOfDailyMaxUtilPercent = $avgMaxUtil
            CostAmount       = $costResult.Cost
            Currency         = $costResult.Currency
            CostPeriod       = $costResult.Period
            RecommendedCapacity = $rightSizing.RecommendedCapacity
            RightSizingAction = $rightSizing.RecommendedAction
            EstimatedNewCost = $rightSizing.EstimatedCost
            PotentialSavings = $rightSizing.PotentialSavings
            TierChangeOpportunity = $rightSizing.TierChangeOpportunity
            TierChangeSavings = $rightSizing.TierChangeSavings
            ResourceId       = $dbResId
        }
    }
    
    # Per-subscription completion summary
    $subPools = $report | Where-Object { $_.SubscriptionId -eq $sub.Id -and $_.ResourceType -eq "ElasticPool" }
    $subDatabases = $report | Where-Object { $_.SubscriptionId -eq $sub.Id -and $_.ResourceType -eq "Database" }
    Write-Host ""
    Write-Host "  ✓ Completed subscription: $($sub.Name)" -ForegroundColor Green
    Write-Host "    - Elastic pools analyzed: $($subPools.Count)" -ForegroundColor Gray
    Write-Host "    - Standalone databases analyzed: $($subDatabases.Count)" -ForegroundColor Gray
    Write-Host ""
}

# Final summary
$scriptEndTime = Get-Date
$elapsedTime = $scriptEndTime - $scriptStartTime

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Analysis Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total subscriptions processed: $totalSubscriptions" -ForegroundColor Yellow
Write-Host "Total elastic pools analyzed: $(@($report | Where-Object { $_.ResourceType -eq 'ElasticPool' }).Count)" -ForegroundColor Yellow
Write-Host "Total standalone databases analyzed: $(@($report | Where-Object { $_.ResourceType -eq 'Database' }).Count)" -ForegroundColor Yellow
Write-Host "Total resources: $($report.Count)" -ForegroundColor Yellow

$withRecommendations = ($report | Where-Object { $_.RightSizingAction -in @("ScaleUp", "ScaleDown", "ScaleDown-Unused") }).Count
$totalSavings = ($report | Where-Object { $_.PotentialSavings -gt 0 } | Measure-Object -Property PotentialSavings -Sum).Sum
if ($null -eq $totalSavings) { $totalSavings = 0 }

$totalCurrentCost = ($report | Measure-Object -Property CostAmount -Sum).Sum
if ($null -eq $totalCurrentCost) { $totalCurrentCost = 0 }

Write-Host ""
Write-Host "Resources with right-sizing opportunities: $withRecommendations" -ForegroundColor Magenta

$currency = ($report | Where-Object { $_.Currency } | Select-Object -First 1).Currency
if (-not $currency) { $currency = "" }

Write-Host "Total current cost (last month): $([math]::Round($totalCurrentCost, 2)) $currency" -ForegroundColor Magenta
if ($totalSavings -gt 0) {
    Write-Host "Total potential savings: $([math]::Round($totalSavings, 2)) $currency" -ForegroundColor Magenta
}

Write-Host ""
Write-Host "Start time: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
Write-Host "End time: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
Write-Host "Elapsed time: $($elapsedTime.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
Write-Host ""

# Adjust report based on parameters
$finalReport = $report | ForEach-Object {
    $item = $_
    if (-not $IncludeScaleUpRecommendations -and $item.RightSizingAction -eq "ScaleUp") {
        # Convert ScaleUp to NoChange to keep resources in report but suppress scale-up recommendations
        $item.RightSizingAction = "NoChange"
        $item.RecommendedCapacity = $item.Capacity
        $item.EstimatedNewCost = $item.CostAmount
        $item.PotentialSavings = 0
    }
    $item
}

$scaleUpCount = ($report | Where-Object { $_.RightSizingAction -eq "ScaleUp" }).Count
if ($scaleUpCount -gt 0 -and -not $IncludeScaleUpRecommendations) {
    Write-Host ""
    Write-Host "Note: $scaleUpCount ScaleUp recommendation(s) converted to NoChange." -ForegroundColor Yellow
    Write-Host "      Set `$IncludeScaleUpRecommendations = `$true to see scale-up recommendations." -ForegroundColor Yellow
}

$timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
$csvPath = "AzSqlRightsizingReport-$timestamp.csv"
$finalReport | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✓ Report exported: $csvPath" -ForegroundColor Green
Write-Host "  Resources in report: $($finalReport.Count)" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan