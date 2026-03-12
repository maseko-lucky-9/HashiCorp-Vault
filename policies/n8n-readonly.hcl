{
  "name": "Vault Secret Lookup",
  "nodes": [
    {
      "parameters": {},
      "id": "start-node",
      "name": "Manual Trigger",
      "type": "n8n-nodes-base.manualTrigger",
      "typeVersion": 1,
      "position": [250, 300]
    },
    {
      "parameters": {
        "method": "GET",
        "url": "http://vault.vault.svc.cluster.local:8200/v1/secret/data/n8n/live/api-keys",
        "authentication": "genericCredentialType",
        "genericAuthType": "httpHeaderAuth",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [
            {
              "name": "X-Vault-Token",
              "value": "={{ $env.VAULT_TOKEN }}"
            }
          ]
        },
        "options": {
          "response": {
            "response": {
              "responseFormat": "json"
            }
          }
        }
      },
      "id": "vault-read-node",
      "name": "Read Vault Secret",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [480, 300]
    },
    {
      "parameters": {
        "jsCode": "// Extract the secret data from Vault's KV v2 response envelope\nconst vaultResponse = $input.first().json;\nconst secrets = vaultResponse.data.data;\n\nreturn [{\n  json: {\n    api_key: secrets.API_KEY,\n    api_secret: secrets.API_SECRET,\n    metadata: {\n      version: vaultResponse.data.metadata.version,\n      created_time: vaultResponse.data.metadata.created_time\n    }\n  }\n}];"
      },
      "id": "parse-node",
      "name": "Parse Secret Data",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [710, 300]
    }
  ],
  "connections": {
    "Manual Trigger": { "main": [[{ "node": "Read Vault Secret", "type": "main", "index": 0 }]] },
    "Read Vault Secret": { "main": [[{ "node": "Parse Secret Data", "type": "main", "index": 0 }]] }
  }
}
