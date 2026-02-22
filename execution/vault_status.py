#!/usr/bin/env python3
"""
Vault cluster status checker.

Queries all Vault pods in a Kubernetes namespace and reports their
initialization, seal, and Raft peer status. Designed to be called by
the orchestration layer before init, unseal, or backup operations.

Usage:
    python vault_status.py
    python vault_status.py --namespace vault --replicas 3 --output json
"""

import sys
import argparse
import subprocess
import json
from datetime import datetime
from pathlib import Path
from utils import load_env, setup_logging, write_output


def run_kubectl(args, capture=True):
    """
    Run a kubectl command and return stdout.

    Args:
        args (list[str]): kubectl arguments (without the 'kubectl' prefix)
        capture (bool): If True, capture and return stdout

    Returns:
        str: Command stdout

    Raises:
        subprocess.CalledProcessError: On non-zero exit code
    """
    cmd = ['kubectl'] + args
    result = subprocess.run(
        cmd,
        capture_output=capture,
        text=True,
        timeout=30
    )
    result.check_returncode()
    return result.stdout.strip()


def get_pod_status(namespace, pod_name, log):
    """
    Get the status of a single Vault pod.

    Args:
        namespace (str): Kubernetes namespace
        pod_name (str): Pod name (e.g. vault-0)
        log (callable): Logging function

    Returns:
        dict: Pod status with keys: pod, phase, ready, initialized, sealed, version, error
    """
    status = {
        'pod': pod_name,
        'phase': 'Unknown',
        'ready': False,
        'initialized': None,
        'sealed': None,
        'version': None,
        'ha_mode': None,
        'error': None
    }

    # Check pod phase
    try:
        phase = run_kubectl([
            'get', 'pod', pod_name, '-n', namespace,
            '-o', 'jsonpath={.status.phase}'
        ])
        status['phase'] = phase
    except subprocess.CalledProcessError:
        status['error'] = f'Pod {pod_name} not found'
        log('ERROR', status['error'])
        return status

    # Check readiness
    try:
        ready = run_kubectl([
            'get', 'pod', pod_name, '-n', namespace,
            '-o', 'jsonpath={.status.containerStatuses[0].ready}'
        ])
        status['ready'] = ready.lower() == 'true'
    except (subprocess.CalledProcessError, IndexError):
        pass

    # Get Vault status via exec
    try:
        vault_output = run_kubectl([
            'exec', '-n', namespace, pod_name, '--',
            'vault', 'status', '-format=json'
        ])
        vault_status = json.loads(vault_output)
        status['initialized'] = vault_status.get('initialized', None)
        status['sealed'] = vault_status.get('sealed', None)
        status['version'] = vault_status.get('version', None)
        status['ha_mode'] = vault_status.get('ha_mode', None)
    except subprocess.CalledProcessError:
        # vault status returns exit code 2 if sealed, 1 if error
        try:
            vault_output = subprocess.run(
                ['kubectl', 'exec', '-n', namespace, pod_name, '--',
                 'vault', 'status', '-format=json'],
                capture_output=True, text=True, timeout=30
            )
            if vault_output.stdout:
                vault_status = json.loads(vault_output.stdout)
                status['initialized'] = vault_status.get('initialized', None)
                status['sealed'] = vault_status.get('sealed', None)
                status['version'] = vault_status.get('version', None)
                status['ha_mode'] = vault_status.get('ha_mode', None)
            else:
                status['error'] = 'Vault not responding'
        except Exception as e:
            status['error'] = f'Cannot query Vault: {str(e)}'
            log('WARNING', status['error'])
    except json.JSONDecodeError:
        status['error'] = 'Invalid JSON from vault status'

    return status


def get_pvc_status(namespace, log):
    """
    Get PVC status for the Vault namespace.

    Args:
        namespace (str): Kubernetes namespace
        log (callable): Logging function

    Returns:
        list[dict]: PVC info with keys: name, status, volume, capacity, storage_class
    """
    pvcs = []
    try:
        output = run_kubectl([
            'get', 'pvc', '-n', namespace, '-o', 'json'
        ])
        pvc_list = json.loads(output)
        for item in pvc_list.get('items', []):
            pvcs.append({
                'name': item['metadata']['name'],
                'status': item['status'].get('phase', 'Unknown'),
                'volume': item['spec'].get('volumeName', ''),
                'capacity': item['status'].get('capacity', {}).get('storage', ''),
                'storage_class': item['spec'].get('storageClassName', '')
            })
    except subprocess.CalledProcessError:
        log('WARNING', f'Could not retrieve PVCs in namespace {namespace}')
    except json.JSONDecodeError:
        log('WARNING', 'Invalid JSON from kubectl get pvc')

    return pvcs


def check_cluster(namespace, replicas, log):
    """
    Perform a full cluster health check.

    Args:
        namespace (str): Kubernetes namespace
        replicas (int): Expected number of Vault pods
        log (callable): Logging function

    Returns:
        dict: Cluster status summary
    """
    log('INFO', f'Checking Vault cluster in namespace "{namespace}" ({replicas} expected replicas)')

    pods = []
    for i in range(replicas):
        pod_name = f'vault-{i}'
        log('INFO', f'Checking {pod_name}...')
        pod_status = get_pod_status(namespace, pod_name, log)
        pods.append(pod_status)

    pvcs = get_pvc_status(namespace, log)

    # Compute summary
    total_pods = len(pods)
    running = sum(1 for p in pods if p['phase'] == 'Running')
    ready = sum(1 for p in pods if p['ready'])
    sealed = sum(1 for p in pods if p['sealed'] is True)
    initialized = any(p['initialized'] for p in pods)

    cluster = {
        'timestamp': datetime.now().isoformat(),
        'namespace': namespace,
        'expected_replicas': replicas,
        'pods': pods,
        'pvcs': pvcs,
        'summary': {
            'total_pods': total_pods,
            'running': running,
            'ready': ready,
            'sealed': sealed,
            'initialized': initialized,
            'healthy': running == replicas and ready == replicas and sealed == 0
        }
    }

    # Log summary
    health = '✅ HEALTHY' if cluster['summary']['healthy'] else '⚠️  DEGRADED'
    log('INFO', f'Cluster status: {health}')
    log('INFO', f'  Pods: {running}/{replicas} running, {ready}/{replicas} ready, {sealed} sealed')
    log('INFO', f'  PVCs: {len(pvcs)} found')

    if not initialized:
        log('WARNING', 'Vault is NOT initialized — run directives/initialize-vault.md')
    elif sealed > 0:
        log('WARNING', f'{sealed} pod(s) are sealed — run directives/unseal-vault.md')

    return cluster


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Check Vault cluster status across all pods',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument(
        '--namespace', '-n',
        default='vault',
        help='Kubernetes namespace (default: vault)'
    )

    parser.add_argument(
        '--replicas', '-r',
        type=int,
        default=3,
        help='Expected number of Vault replicas (default: 3)'
    )

    parser.add_argument(
        '--output-format',
        choices=['json', 'text'],
        default='text',
        help='Output format (default: text)'
    )

    parser.add_argument(
        '--output-dir',
        default='./data',
        help='Output directory for JSON reports (default: ./data)'
    )

    args = parser.parse_args()

    load_env()
    log = setup_logging('vault_status')

    try:
        cluster = check_cluster(args.namespace, args.replicas, log)

        if args.output_format == 'json':
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            filename = f'vault_status_{timestamp}.json'
            output_path = Path(args.output_dir) / filename
            write_output(cluster, output_path, 'json')
            log('INFO', f'Report written to: {output_path}')
            print(str(output_path))
        else:
            # Text summary to stdout
            print(f"\nVault Cluster Status — {cluster['timestamp']}")
            print("=" * 60)
            for pod in cluster['pods']:
                seal_icon = '🔒' if pod['sealed'] else '🔓' if pod['sealed'] is False else '❓'
                ready_icon = '✅' if pod['ready'] else '❌'
                ha = f" ({pod['ha_mode']})" if pod['ha_mode'] else ''
                err = f" — {pod['error']}" if pod['error'] else ''
                print(f"  {pod['pod']}: {ready_icon} {pod['phase']} {seal_icon}{ha}{err}")
            print()
            for pvc in cluster['pvcs']:
                print(f"  PVC {pvc['name']}: {pvc['status']} ({pvc['capacity']}) [{pvc['storage_class']}]")
            print()
            s = cluster['summary']
            health = '✅ HEALTHY' if s['healthy'] else '⚠️  DEGRADED'
            print(f"  Status: {health}")
            print(f"  Pods: {s['running']}/{s['total_pods']} running, {s['ready']}/{s['total_pods']} ready")

        # Exit code reflects health
        sys.exit(0 if cluster['summary']['healthy'] else 1)

    except Exception as e:
        log('ERROR', f'Status check failed: {str(e)}')
        sys.exit(2)


if __name__ == '__main__':
    main()
