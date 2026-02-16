"""
Shared utility functions for execution layer scripts.

This module provides common functionality used across multiple execution scripts,
including environment variable loading, logging setup, and output formatting.
"""

import os
import sys
import json
from pathlib import Path
from datetime import datetime
from dotenv import load_dotenv


def load_env():
    """
    Load environment variables from .env file in project root.
    
    Searches for .env file starting from the current script's directory
    and walking up to find the project root.
    """
    # Start from current file's directory and walk up
    current_path = Path(__file__).resolve().parent
    
    while current_path != current_path.parent:
        env_file = current_path / '.env'
        if env_file.exists():
            load_dotenv(env_file)
            return
        current_path = current_path.parent
    
    # If no .env found, try loading from current working directory
    load_dotenv()


def get_env_or_fail(key, error_message=None):
    """
    Retrieve environment variable or exit with error.
    
    Args:
        key (str): Environment variable name
        error_message (str, optional): Custom error message
        
    Returns:
        str: Value of the environment variable
        
    Raises:
        SystemExit: If the environment variable is not set
    """
    value = os.environ.get(key)
    if value is None:
        msg = error_message or f"Required environment variable '{key}' is not set. Check your .env file."
        print(f"ERROR: {msg}", file=sys.stderr)
        sys.exit(1)
    return value


def setup_logging(script_name):
    """
    Configure basic logging to stderr with timestamp and script name.
    
    Args:
        script_name (str): Name of the calling script for log prefix
        
    Returns:
        function: A log function that can be called with (level, message)
    """
    def log(level, message):
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        print(f"[{timestamp}] [{script_name}] [{level}] {message}", file=sys.stderr)
    
    return log


def write_output(data, path, format='json'):
    """
    Write data to file in specified format.
    
    Args:
        data (dict): Data to write
        path (str or Path): Output file path
        format (str): Output format - 'json' or 'markdown'
        
    Raises:
        ValueError: If format is not supported
        IOError: If file cannot be written
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    
    if format == 'json':
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
    
    elif format == 'markdown':
        with open(path, 'w', encoding='utf-8') as f:
            f.write(f"# {data.get('title', 'Untitled')}\n\n")
            f.write(f"**URL:** {data.get('url', 'N/A')}\n\n")
            f.write(f"**Scraped:** {data.get('timestamp', 'N/A')}\n\n")
            f.write("---\n\n")
            f.write(data.get('content', ''))
            
            if 'links' in data and data['links']:
                f.write("\n\n## Discovered Links\n\n")
                for link in data['links']:
                    f.write(f"- {link}\n")
    
    else:
        raise ValueError(f"Unsupported format: {format}. Use 'json' or 'markdown'.")
