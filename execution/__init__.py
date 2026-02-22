"""
Execution layer package.

This package contains deterministic Python scripts that handle API calls,
data processing, file operations, and other concrete tasks as directed by
the orchestration layer.

Available modules:
- vault_status: Vault cluster health checker (pre-flight for init/unseal/backup)
- scrape_single_site: Web scraping utility
- utils: Shared utilities (logging, env, output)
"""

__version__ = '1.0.0'
