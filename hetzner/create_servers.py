#!/usr/bin/env python3
"""
Simple Hetzner Server Creator

Creates N Hetzner Cloud servers with specified configuration.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

try:
    from hcloud import Client
    from hcloud.images import Image
    from hcloud.server_types import ServerType
    from hcloud.ssh_keys import SSHKey
    from hcloud.servers.domain import Server
except ImportError as e:
    print(f"Missing required library: {e}")
    print("Install with: pip install hcloud")
    sys.exit(1)


# Server name prefix
SERVER_PREFIX = "hetzner-runner"


def get_cloud_init_config(github_token: str, runner_name: str, runner_count: int = 2) -> str:
    """Generate cloud-init configuration with GitHub token injected."""
    return f"""#cloud-config
package_update: true
package_upgrade: true
packages:
  - curl
  - git
  - ca-certificates

runcmd:
  # Install Docker
  - curl -fsSL https://get.docker.com -o get-docker.sh
  - sh get-docker.sh
  - usermod -aG docker root

  # Add Armbian GPG key
  - curl -fsSL https://apt.armbian.com/armbian.key | gpg --dearmor -o /usr/share/keyrings/armbian.gpg

  # Add Armbian config repository
  - |
    cat << EOF | tee /etc/apt/sources.list.d/armbian-config.sources > /dev/null
    Types: deb
    URIs: https://github.armbian.com/configng
    Suites: stable
    Components: main
    Signed-By: /usr/share/keyrings/armbian.gpg
    EOF

  # Update package list and install armbian-config
  - apt-get update
  - apt-get install -y armbian-config

  # Create 10GB swap file
  - fallocate -l 10G /swapfile
  - chmod 600 /swapfile
  - mkswap /swapfile
  - swapon /swapfile
  - echo '/swapfile none swap sw 0 0' >> /etc/fstab

  # Install GitHub Actions runners (start=1 stop={runner_count} installs {runner_count} runners)
  - armbian-config --api module_armbian_runners install gh_token={github_token} runner_name={runner_name} start=1 stop={runner_count} label_primary=alfa label_secondary=images organisation=armbian

  # Clean up
  - rm -f get-docker.sh

final_message: "Server configuration complete!"
"""


def create_server(
    client: Client,
    name: str,
    server_type: str,
    image: str,
    ssh_key_name: str,
    github_token: str,
    delete_existing: bool = False,
    runner_count: int = 2,
) -> dict:
    """
    Create a single Hetzner server.

    Args:
        client: Hetzner client
        name: Server name
        server_type: Server type (e.g., cax21, cax31)
        image: Image name (e.g., ubuntu-22.04)
        ssh_key_name: SSH key name in Hetzner
        delete_existing: Delete existing server if present
        runner_count: Number of runners to install

    Returns:
        Dict with server info
    """
    # Check if server exists
    existing = client.servers.get_by_name(name)
    if existing:
        if delete_existing:
            print(f"Deleting existing server: {name}")
            client.servers.delete(existing)
            time.sleep(2)  # Wait for deletion
        else:
            return {
                "name": name,
                "status": "exists",
                "id": existing.id,
                "public_ip": existing.public_net.ipv4.ip if existing.public_net else None,
            }

    # Get SSH key
    ssh_keys = client.ssh_keys.get_all()
    ssh_key = None
    for key in ssh_keys:
        if key.name == ssh_key_name:
            ssh_key = key
            break

    if not ssh_key:
        print(f"Warning: SSH key '{ssh_key_name}' not found, creating without SSH key")

    # Get cloud-init config with GitHub token
    user_data = get_cloud_init_config(github_token, name, runner_count)

    # Create server
    print(f"Creating server: {name}")
    response = client.servers.create(
        name=name,
        server_type=ServerType(name=server_type),
        image=Image(name=image),
        ssh_keys=[ssh_key] if ssh_key else [],
        user_data=user_data,
    )

    # Wait for server creation to complete
    if response.action:
        response.action.wait_until_finished()

    # Get the server
    server = client.servers.get_by_name(name)

    # Wait for server to be running
    print(f"Waiting for {name} to be running...")
    for _ in range(60):  # Wait up to 5 minutes
        server = client.servers.get_by_name(name)
        if server.status == Server.STATUS_RUNNING:
            break
        time.sleep(5)

    return {
        "name": name,
        "status": server.status,
        "id": server.id,
        "public_ip": server.public_net.ipv4.ip if server.public_net else None,
        "server_type": server.server_type.name,
        "image": server.image.name if server.image else None,
    }


def delete_servers(
    client: Client,
    server_names: list[str],
) -> dict:
    """
    Delete servers by name.

    Args:
        client: Hetzner client
        server_names: List of server names to delete

    Returns:
        Dict with deletion results
    """
    results = []
    for name in server_names:
        server = client.servers.get_by_name(name)
        if server:
            print(f"Deleting server: {name} (ID: {server.id})")
            client.servers.delete(server)
            results.append({"name": name, "status": "deleted", "id": server.id})
        else:
            results.append({"name": name, "status": "not_found"})

    return {"deleted": len([r for r in results if r["status"] == "deleted"])}


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Create Hetzner Cloud servers"
    )
    parser.add_argument(
        "action",
        choices=["create", "delete"],
        help="Action to perform"
    )
    parser.add_argument(
        "--hetzner-token",
        default=os.environ.get("HCLOUD_TOKEN"),
        help="Hetzner Cloud API token (HCLOUD_TOKEN env var)",
    )
    parser.add_argument(
        "--github-token",
        default=os.environ.get("GITHUB_TOKEN"),
        help="GitHub token for runner registration (GITHUB_TOKEN env var)",
    )
    parser.add_argument(
        "--server-type",
        default="cax31",
        help="Server type (default: cax31)",
    )
    parser.add_argument(
        "--image",
        default="ubuntu-24.04",
        help="Image name (default: ubuntu-24.04)",
    )
    parser.add_argument(
        "--ssh-key",
        default="UPLOAD",
        help="SSH key name in Hetzner (default: UPLOAD)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=1,
        help="Number of servers to create (default: 1)",
    )
    parser.add_argument(
        "--index",
        type=int,
        default=0,
        help="Starting index for server names (default: 0)",
    )
    parser.add_argument(
        "--delete-existing",
        action="store_true",
        help="Delete existing servers before creating",
    )
    parser.add_argument(
        "--runner-count",
        type=int,
        default=2,
        help="Number of runners per server (default: 2)",
    )

    args = parser.parse_args()

    if not args.hetzner_token:
        print("Error: Hetzner token required (use --hetzner-token or HCLOUD_TOKEN env var)")
        sys.exit(1)

    # GitHub token only required for create action
    if args.action != "delete" and not args.github_token:
        print("Error: GitHub token required for create action (use --github-token or GITHUB_TOKEN env var)")
        sys.exit(1)

    # Create client
    client = Client(
        token=args.hetzner_token,
        application_name="gh-runner-deployer",
        application_version="1.0.0",
    )

    if args.action == "delete":
        # Delete servers
        server_names = [f"{SERVER_PREFIX}-{i}" for i in range(args.index, args.index + args.count)]
        result = delete_servers(client, server_names)
    else:
        # Create servers
        servers = []
        for i in range(args.count):
            server_name = f"{SERVER_PREFIX}-{args.index + i}"
            server = create_server(
                client,
                name=server_name,
                server_type=args.server_type,
                image=args.image,
                ssh_key_name=args.ssh_key,
                github_token=args.github_token,
                delete_existing=args.delete_existing,
                runner_count=args.runner_count,
            )
            servers.append(server)

        result = {
            "action": "create",
            "servers": servers,
        }

    # Output JSON
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
