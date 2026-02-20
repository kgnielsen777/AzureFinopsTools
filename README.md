# Azure SQL Performance & Cost Optimization Tools

A collection of PowerShell tools for analyzing and optimizing Azure SQL Database costs and performance across multiple subscriptions.

## Available Tools

### [AzSqlRightsizing](./AzSqlRightsizing/)

Comprehensive cost and performance analysis tool for Azure SQL Databases and Elastic Pools.

**Key Features:**
- Multi-subscription cost and utilization analysis
- Smart right-sizing recommendations (80% target utilization)
- Tier change opportunity detection
- Unused database identification
- Timestamped CSV reports with detailed metrics

**Quick Start:**
```powershell
cd AzSqlRightsizing
.\Get-AZSqlRightsizingData.ps1
```

📖 [Full Documentation](./AzSqlRightsizing/README.md)

---

## Prerequisites

All tools require:
- PowerShell 7.0 or higher
- Azure PowerShell modules (Az.Accounts, Az.Sql, Az.Monitor, Az.Resources)
- Azure RBAC roles: Reader, Cost Management Reader, Monitoring Reader

## Getting Started

1. **Install Azure PowerShell modules:**
   ```powershell
   Install-Module -Name Az.Accounts, Az.Sql, Az.Monitor, Az.Resources
   ```

2. **Connect to Azure:**
   ```powershell
   Connect-AzAccount
   ```

3. **Navigate to the tool folder and run:**
   ```powershell
   cd AzSqlRightsizing
   .\Get-AZSqlRightsizingData.ps1
   ```

## Repository Structure

```
AZSQLPerf-cost/
├── README.md                    (this file)
├── AzSqlRightsizing/           (SQL rightsizing tool)
│   ├── Get-AZSqlRightsizingData.ps1
│   ├── README.md
│   ├── LICENSE
│   └── .gitignore
└── (future tools will be added as subfolders)
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

MIT License - See individual tool folders for specific license files.

## Author

Created for optimizing Azure SQL Database costs and performance across enterprise Azure environments.
