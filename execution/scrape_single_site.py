#!/usr/bin/env python3
"""
Scrape a single website and extract content.

This script retrieves content from a given URL, parses the HTML,
and optionally follows links to a specified depth. Output is saved
in either JSON or Markdown format.

Usage:
    python scrape_single_site.py --url https://example.com
    python scrape_single_site.py --url https://example.com --depth 2 --output-format markdown
"""

import sys
import argparse
import requests
from bs4 import BeautifulSoup
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse
from utils import load_env, setup_logging, write_output
import os


def scrape(url, depth=1, output_format='json', visited=None):
    """
    Scrape a URL and optionally follow links.
    
    Args:
        url (str): Target URL to scrape
        depth (int): Number of link levels to follow (1 = only target page)
        output_format (str): Output format ('json' or 'markdown')
        visited (set): Set of already-visited URLs (for recursion)
        
    Returns:
        dict: Structured data containing url, title, content, links, timestamp
        
    Raises:
        requests.RequestException: On HTTP errors or network issues
    """
    log = setup_logging('scrape_single_site')
    
    if visited is None:
        visited = set()
    
    # Avoid revisiting URLs
    if url in visited:
        log('INFO', f'Already visited: {url}')
        return None
    
    visited.add(url)
    log('INFO', f'Scraping: {url}')
    
    # Get User-Agent from environment or use default
    user_agent = os.environ.get('USER_AGENT', 'Mozilla/5.0 (compatible; AgentBot/1.0)')
    
    headers = {
        'User-Agent': user_agent
    }
    
    try:
        # Make HTTP request with timeout
        timeout = int(os.environ.get('REQUEST_TIMEOUT', '30'))
        response = requests.get(url, headers=headers, timeout=timeout)
        response.raise_for_status()
        
    except requests.exceptions.Timeout:
        log('ERROR', f'Request timeout after {timeout}s: {url}')
        raise
    except requests.exceptions.HTTPError as e:
        log('ERROR', f'HTTP error {response.status_code}: {url}')
        raise
    except requests.exceptions.RequestException as e:
        log('ERROR', f'Request failed: {url} - {str(e)}')
        raise
    
    # Parse HTML
    try:
        soup = BeautifulSoup(response.content, 'lxml')
    except Exception:
        # Fallback to html.parser if lxml fails
        soup = BeautifulSoup(response.content, 'html.parser')
    
    # Extract title
    title = soup.title.string if soup.title else urlparse(url).netloc
    
    # Extract text content (remove script and style elements)
    for script_or_style in soup(['script', 'style', 'nav', 'footer', 'header']):
        script_or_style.decompose()
    
    text_content = soup.get_text(separator='\n', strip=True)
    
    # Extract links if we need to go deeper
    links = []
    if depth > 1:
        base_domain = urlparse(url).netloc
        for link in soup.find_all('a', href=True):
            absolute_url = urljoin(url, link['href'])
            link_domain = urlparse(absolute_url).netloc
            
            # Only follow links on the same domain
            if link_domain == base_domain and absolute_url not in visited:
                links.append(absolute_url)
    
    # Build result
    result = {
        'url': url,
        'title': title,
        'content': text_content,
        'links': links,
        'timestamp': datetime.now().isoformat()
    }
    
    log('INFO', f'Successfully scraped: {url} ({len(text_content)} chars, {len(links)} links)')
    
    # Recursively scrape linked pages if depth > 1
    if depth > 1 and links:
        log('INFO', f'Following {len(links)} links (depth={depth-1})')
        for link in links[:10]:  # Limit to first 10 links to avoid excessive scraping
            try:
                scrape(link, depth=depth-1, output_format=output_format, visited=visited)
            except Exception as e:
                log('WARNING', f'Failed to scrape linked page {link}: {str(e)}')
                # Continue with other links
    
    return result


def main():
    """Main entry point for the script."""
    parser = argparse.ArgumentParser(
        description='Scrape a website and extract content',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    
    parser.add_argument(
        '--url',
        required=True,
        help='Target URL to scrape'
    )
    
    parser.add_argument(
        '--depth',
        type=int,
        default=1,
        help='Number of link levels to follow (default: 1)'
    )
    
    parser.add_argument(
        '--output-format',
        choices=['json', 'markdown'],
        default='json',
        help='Output format (default: json)'
    )
    
    parser.add_argument(
        '--output-dir',
        default='./data',
        help='Output directory (default: ./data)'
    )
    
    args = parser.parse_args()
    
    # Load environment variables
    load_env()
    
    log = setup_logging('scrape_single_site')
    
    try:
        # Perform scrape
        result = scrape(args.url, args.depth, args.output_format)
        
        if result is None:
            log('WARNING', 'No content scraped (URL may have been visited already)')
            sys.exit(0)
        
        # Generate output filename
        domain = urlparse(args.url).netloc.replace('.', '_')
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        extension = 'md' if args.output_format == 'markdown' else 'json'
        filename = f"{domain}_{timestamp}.{extension}"
        
        output_path = Path(args.output_dir) / filename
        
        # Write output
        write_output(result, output_path, args.output_format)
        
        log('INFO', f'Output written to: {output_path}')
        print(str(output_path))  # Print path to stdout for orchestration layer
        
    except Exception as e:
        log('ERROR', f'Scraping failed: {str(e)}')
        sys.exit(1)


if __name__ == '__main__':
    main()
