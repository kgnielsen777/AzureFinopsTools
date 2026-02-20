# Azure SQL Cost & Performance Analysis

A PowerShell script to analyze Azure SQL Database and Elastic Pool costs, performance metrics, and provide right-sizing recommendations across multiple Azure subscriptions.

> **Note:** This tool is designed to be used as a subfolder within your existing Azure operations repository.

## Overview

This tool helps you:
- 📊 Analyze SQL Database and Elastic Pool utilization across all your Azure subscriptions
- 💰 Track actual monthly costs from Azure Cost Management
- 🎯 Get automated right-sizing recommendations to optimize costs
- 🔍 Identify unused databases wasting money
- 📈 Review average and peak utilization patterns
- 💾 Export comprehensive reports to CSV with timestamps

## Features

- **Multi-Subscription Support**: Automatically processes all enabled subscriptions
- **Cost Data**: Retrieves actual monthly costs from Azure Cost Management API
- **Performance Metrics**: Collects 30-day average and peak utilization (DTU or vCore)
- **Smart Right-Sizing**: 
  - Recommends optimal capacity based on 80% target utilization
  - Identifies over-provisioned resources
  - Flags unused databases (0% utilization)
  - Prevents incorrect scale-up recommendations for under-utilized resources
- **Efficient Querying**: 
  - Resource group scoped cost queries (not full subscription)
  - Built-in pagination for large datasets
  - Automatic retry logic for rate limiting
- **Comprehensive Output**: Single CSV with all databases, pools, costs, and recommendations

## Prerequisites

### Required PowerShell Modules
```powershell
Install-Module -Name Az.Accounts
Install-Module -Name Az.Sql
Install-Module -Name Az.Monitor
Install-Module -Name Az.Resources
```

### Azure Permissions

You need the following Azure RBAC roles:
- **Reader** role on subscriptions (to list resources)
- **Cost Management Reader** role on subscriptions (to query cost data)
- **Monitoring Reader** role (to access metrics)

## Installation

This tool is designed to be used as a subfolder within your existing Azure operations repository.

1. Add to your existing repository:
```bash
# Navigate to your repository
cd your-azure-repo

# Create the AzSqlRightsizing folder structure
mkdir AzSqlRightsizing
cd AzSqlRightsizing

# Copy the script files:
# - Get-AZSqlRightsizingData.ps1
# - README.md
# - LICENSE
# - .gitignore
```

Or clone as a subfolder:
```bash
cd your-azure-repo
git clone https://github.com/yourusername/azure-sql-cost-analysis.git AzSqlRightsizing
```

2. Ensure you have the required PowerShell modules installed (see Prerequisites)

## Usage

### Basic Usage

1. Navigate to the AzSqlRightsizing folder:
```powershell
cd AzSqlRightsizing
```

2. Connect to Azure:
```powershell
Connect-AzAccount
```

3. Run the script:
```powershell
.\Get-AZSqlRightsizingData.ps1
```

The script will:
- Process all enabled subscriptions
- Query cost data for resource groups containing SQL servers
- Collect performance metrics for the last 30 days
- Generate right-sizing recommendations
- Export results to `AzSqlRightsizingReport-YYYY-MM-DD-HHmm.csv`

### Progress Tracking

The script provides real-time progress indicators:

**During execution:**
- Total subscriptions to process
- Current subscription progress (e.g., "[2/5] Processing subscription: MySubscription")
- Resources found per subscription
- Per-subscription completion summary

**Final summary:**
- Total subscriptions processed
- Total elastic pools and databases analyzed
- Resources with right-sizing opportunities
- Total potential savings
- Elapsed time

Example output:
```
========================================
Azure SQL Cost & Performance Analysis
========================================
Total subscriptions to process: 3
Start time: 2026-02-01 14:30:00

========================================
[1/3] Processing subscription: Production
========================================
  Found SQL servers in 5 resource group(s)
  Found 8 elastic pool(s)
  Processing standalone databases...
  Found 12 standalone database(s)

  ✓ Completed subscription: Production
    - Elastic pools analyzed: 8
    - Standalone databases analyzed: 12

========================================
Analysis Complete
========================================
Total subscriptions processed: 3
Total elastic pools analyzed: 18
Total standalone databases analyzed: 25
Total resources: 43

Resources with right-sizing opportunities: 12
Total potential savings: 3245.67 DKK

Elapsed time: 00:08:23

✓ Report exported: AzSqlRightsizingReport-2026-02-20-1430.csv
```

### Configuration Options

Edit `Get-AZSqlRightsizingData.ps1` to customize behavior:

**Filter specific subscriptions:**
```powershell
# Process only specific subscription
$subscriptions = (Get-AzSubscription | Where-Object { $_.Name -eq "MySubscription" })

# Process all enabled subscriptions (default)
$subscriptions = (Get-AzSubscription | Where-Object { $_.State -eq "Enabled" })
```

**Adjust API rate limiting:**
```powershell
$apiDelayMs = 500  # milliseconds between API calls (increase if hitting rate limits)
```

**Include scale-up recommendations:**
```powershell
# By default, script focuses on cost-saving opportunities (scale down, unused resources)
# Set to $true to also include over-utilized resources that need more capacity
$IncludeScaleUpRecommendations = $false  # default: false (cost-savings focus)
$IncludeScaleUpRecommendations = $true   # include scale-up recommendations
```

## Output

### CSV Columns

| Column | Description |
|--------|-------------|
| SubscriptionId | Azure subscription GUID |
| SubscriptionName | Friendly subscription name |
| ResourceGroup | Resource group name |
| ServerName | SQL Server name |
| ResourceType | "ElasticPool" or "Database" |
| ResourceName | Elastic pool or database name |
| PoolName | Elastic pool name (if applicable) |
| DatabaseCount | Number of databases (pools) or 1 (standalone DB) |
| ServiceTier | Basic, Standard, Premium, GeneralPurpose, BusinessCritical |
| SkuName | Specific SKU identifier |
| Capacity | Current DTU or vCore capacity |
| ComputeModel | Serverless, Provisioned, etc. |
| DtuOrVCore | "DTU" or "vCore" |
| AvgUtilPercent | 30-day average utilization % |
| AvgOfDailyMaxUtilPercent | Average of daily peak utilization % |
| CostAmount | Actual monthly cost from Azure Cost Management |
| Currency | Billing currency (e.g., DKK, USD, EUR) |
| CostPeriod | Cost period (e.g., "jan. 2026") |
| RecommendedCapacity | Suggested DTU/vCore capacity |
| RightSizingAction | ScaleUp, ScaleDown, NoChange, Unused, ScaleDown-Unused, NoMetrics |
| EstimatedNewCost | Projected cost at recommended capacity |
| PotentialSavings | Monthly savings (positive) or additional cost (negative) |
| TierChangeOpportunity | Suggested service tier downgrade for low-utilization resources |
| TierChangeSavings | Estimated monthly savings from tier change |
| ResourceId | Full Azure resource ID |

### Right-Sizing Actions Explained

- **ScaleDown**: Resource is under-utilized, can reduce capacity
- **ScaleUp**: Resource is over-utilized (>80% peak), needs more capacity
- **NoChange**: Resource is well-sized (near 80% target utilization)
- **Unused**: 0% utilization, already at minimum tier (consider deletion)
- **ScaleDown-Unused**: 0% utilization, can scale down to minimum tier
- **NoMetrics**: No performance data available (possible error)

### Tier Change Opportunities

For resources showing **NoChange** but at minimum capacity with <20% utilization, the **TierChangeOpportunity** column suggests:

- **Standard → Basic**: Standard 10 DTU with low usage could move to Basic 5 DTU (~65% savings)
- **Premium → Standard**: Premium 125 DTU with low usage could move to Standard 10 DTU (~80% savings)
- **vCore → DTU**: GeneralPurpose 1 vCore with low usage and high cost could move to Basic/Standard DTU (~70% savings)

**Note**: Tier changes require manual intervention and may have feature limitations. Always test in non-production first.

## Example Analysis

```powershell
# Load and analyze results (use your specific date/time)
$data = Import-Csv "AzSqlRightsizingReport-2026-02-20-1430.csv"

# Find biggest savings opportunities
$data | Where-Object { [decimal]$_.PotentialSavings -gt 100 } | 
    Sort-Object { [decimal]$_.PotentialSavings } -Descending |
    Select-Object ResourceName, Capacity, RecommendedCapacity, CostAmount, PotentialSavings

# Find unused databases
$data | Where-Object { $_.RightSizingAction -like "*Unused*" } |
    Select-Object ResourceName, ServerName, CostAmount, RightSizingAction

# Find tier change opportunities
$data | Where-Object { $_.TierChangeOpportunity -ne "" } |
    Sort-Object { [decimal]$_.TierChangeSavings } -Descending |
    Select-Object ResourceName, ServiceTier, Capacity, AvgOfDailyMaxUtilPercent, CostAmount, TierChangeOpportunity, TierChangeSavings

# Calculate total potential savings
$totalSavings = ($data | ForEach-Object { [decimal]$_.PotentialSavings } | Measure-Object -Sum).Sum
$tierChangeSavings = ($data | ForEach-Object { [decimal]$_.TierChangeSavings } | Measure-Object -Sum).Sum
Write-Host "Total potential monthly savings (capacity): $totalSavings"
Write-Host "Total potential monthly savings (tier changes): $tierChangeSavings"
```

## How It Works

1. **Discovery**: Queries all SQL servers across enabled subscriptions
2. **Cost Query**: Retrieves cost data from Azure Cost Management API for resource groups containing SQL servers
3. **Metrics Collection**: Gathers 30-day performance metrics (average and daily peak)
4. **Analysis**: Calculates right-sizing recommendations based on 80% target utilization
5. **Export**: Generates comprehensive CSV report with all data and recommendations

### Right-Sizing Logic

The script analyzes 30-day performance metrics to determine optimal capacity for each resource.

#### Core Principles

1. **Target Utilization: 80%**
   - Aims for 80% utilization to leave 20% headroom for traffic spikes
   - Balances cost efficiency with performance safety margin
   - Based on average of daily peak utilization (not overall average)

2. **Capacity Calculation**
   ```
   Needed Capacity = (Current Capacity × Daily Peak Utilization) / 80%
   ```
   - Finds the smallest tier that meets this need
   - Rounds up to next available tier (DTU: 5,10,20,50... | vCore: 1,2,4,6,8...)

3. **Decision Logic**
   - **ScaleDown**: Peak util < 80% AND recommended capacity < current capacity
     - Example: 100 DTU with 40% peak → Recommend 50 DTU (saves ~50%)
   - **ScaleUp**: Peak util > 80% AND recommended capacity > current capacity *(excluded by default)*
     - Example: 50 DTU with 95% peak → Recommend 100 DTU (prevents performance issues)
   - **NoChange**: Recommended capacity = current capacity
     - Already well-sized OR at minimum tier with low utilization
   - **Unused**: 0% utilization, already at minimum tier
     - Consider deletion or deallocation
   - **ScaleDown-Unused**: 0% utilization, can scale to minimum tier
     - Scale down then consider deletion
   - **NoMetrics**: No performance data available
     - Possible permissions issue or newly created resource

4. **Special Cases**
   - **Minimum Tier Protection**: Won't recommend below minimum (Basic:5, Standard:10, Premium:125, vCore:1)
   - **Under-Utilized Resources**: If already below 80%, won't recommend scale-up
   - **Zero Utilization**: Distinguishes true 0% usage from missing metrics

5. **Tier Change Detection**
   - Resources at minimum capacity with <20% peak utilization get tier downgrade suggestions
   - Examples: Standard 10 DTU → Basic 5 DTU, vCore 1 → Standard 10 DTU
   - Requires manual intervention (not automated)

6. **Cost Estimation**
   - Uses linear scaling: `New Cost = Current Cost × (New Capacity / Current Capacity)`
   - **Approximation only** - actual costs vary by:
     - Serverless vs provisioned compute
     - Regional pricing differences
     - Reserved capacity discounts
     - Billing cycles and proration

#### Metric Selection

- **Primary Metric**: `AvgOfDailyMaxUtilPercent` (average of daily peak utilization)
  - More conservative than overall average
  - Captures peak load patterns
  - Better represents actual capacity needs
- **DTU Metric**: `dtu_consumption_percent`
- **vCore Metric**: `cpu_percent`
- **Time Window**: Last 30 days with daily grain

#### Filtering (Default Behavior)

- **Scale-Up Excluded by Default**: Focuses on cost-saving opportunities
  - Set `$IncludeScaleUpRecommendations = $true` to include performance optimization recommendations
- **Rationale**: Most organizations prioritize cost reduction over preemptive scaling
- **Use Scale-Up When**: Investigating performance issues or capacity planning

## Limitations

- Cost estimates are approximations based on linear scaling
- Actual costs may vary due to pricing model differences (e.g., serverless vs provisioned)
- Metrics require 30 days of history for accurate recommendations
- Portal costs may differ from API costs due to aggregation methods

## Troubleshooting

**Rate Limiting (429 errors)**:
- Increase `$apiDelayMs` value
- Script includes automatic retry with exponential backoff

**No cost data for some resources**:
- Verify Cost Management Reader role assignment
- Check if resource existed during the cost period (last complete month)

**No metrics data**:
- Verify Monitoring Reader role assignment
- Ensure metrics are enabled for the database/pool
- Check if resource was recently created (<30 days)

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

MIT License - See LICENSE file for details

## Author

Created for optimizing Azure SQL Database costs and performance across enterprise Azure environments.

## Version History

- **v1.4** - Current version
  - Added tier change opportunity detection
  - Added scale-up filtering parameter
  - Renamed script to Get-AZSqlRightsizingData.ps1
  - Timestamped CSV output (YYYY-MM-DD-HHmm)
  - Progress tracking with subscription counters
  - Comprehensive comment-based help
- **v1.3** - Resource group scoping and pagination support
- **v1.2** - Added unused database detection
- **v1.1** - Added right-sizing recommendations
- **v1.0** - Initial release with basic cost and utilization analysis
