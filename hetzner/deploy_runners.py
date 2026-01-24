#!/usr/bin/env python3
"""
Hetzner GitHub Actions Runner Deployment Script

This script creates Hetzner Cloud servers and installs GitHub Actions runners
using armbian-config.
"""

from __future__ import annotations

import argparse
import io
import os
import sys
import time
import json
from pathlib import Path
from typing import List, Dict, Optional

try:
    from hcloud import Client
    from hcloud.images import Image
    from hcloud.server_types import ServerType
    from hcloud.ssh_keys import SSHKey
    from hcloud.actions import Action
    from hcloud.servers.domain import Server
    import paramiko
except ImportError as e:
    print(f"Missing required library: {e}")
    print("Install with: pip install hcloud paramiko")
    sys.exit(1)


# Machine names for runners
MACHINE_NAMES = [
    "Faerie", "November", "Raven", "Hammer",
    "Foxtrot", "Papa", "Chimera", "Panther"
]


class RunnerDeployer:
    """Manages Hetzner server creation and runner deployment."""

    def __init__(
        self,
        hetzner_token: str,
        github_token: str,
        ssh_key_path: Optional[str] = None,
        ssh_key_name: str = "TORRENT",
        machine_type: str = "cax31",
        image_name: str = "ubuntu-22.04",
        runner_name: str = "runner",
        start: int = 1,
        stop: int = 24,
        label_primary: str = "self-hosted",
        label_secondary: str = "",
        organisation: str = "",
    ):
        """
        Initialize the deployer.

        Args:
            hetzner_token: Hetzner Cloud API token
            github_token: GitHub personal access token
            ssh_key_path: Path to SSH private key (optional, uses env SSH_KEY if not provided)
            ssh_key_name: Name of SSH key in Hetzner Cloud
            machine_type: Hetzner server type (e.g., cax21, cax31, cax41)
            image_name: OS image name
            runner_name: Base name for the runner
            start: Start hour for runner availability
            stop: Stop hour for runner availability
            label_primary: Primary labels for the runner
            label_secondary: Secondary labels for the runner
            organisation: GitHub organization name
        """
        self.hetzner_token = hetzner_token
        self.github_token = github_token
        self.ssh_key_path = ssh_key_path
        self.ssh_key_name = ssh_key_name
        self.machine_type = machine_type
        self.image_name = image_name
        self.runner_name = runner_name
        self.start = start
        self.stop = stop
        self.label_primary = label_primary
        self.label_secondary = label_secondary
        self.organisation = organisation

        self.client = Client(
            token=hetzner_token,
            application_name="armbian-runner-deployer",
            application_version="1.0.0",
        )

        # Load SSH key content for Paramiko
        self._init_ssh_key()

    def _init_ssh_key(self):
        """Initialize SSH key from file or environment."""
        if self.ssh_key_path and os.path.exists(self.ssh_key_path):
            with open(self.ssh_key_path, 'r') as f:
                self.ssh_key_content = f.read()
        else:
            # Try environment variable
            self.ssh_key_content = os.environ.get('SSH_KEY', '')
            if not self.ssh_key_content:
                raise ValueError("SSH key not found. Provide ssh_key_path or set SSH_KEY env var.")

    def get_ssh_key(self) -> Optional[SSHKey]:
        """Get the SSH key object from Hetzner."""
        ssh_keys = self.client.ssh_keys.get_all()
        for key in ssh_keys:
            if key.name == self.ssh_key_name:
                return key
        return None

    def server_exists(self, name: str) -> bool:
        """Check if a server with the given name exists."""
        servers = self.client.servers.get_all()
        return any(s.name == name for s in servers)

    def delete_server(self, name: str) -> bool:
        """Delete a server by name."""
        servers = self.client.servers.get_all()
        for server in servers:
            if server.name == name:
                print(f"Deleting existing server: {name} (ID: {server.id})")
                self.client.servers.delete(server)
                return True
        return False

    def wait_for_server_running(self, server_name: str, timeout: int = 300) -> bool:
        """
        Wait for server to be in running state.

        Args:
            server_name: Name of the server to wait for
            timeout: Maximum time to wait in seconds

        Returns:
            True if server is running, False if timeout
        """
        print(f"Waiting for server {server_name} to be running...")
        start_time = time.time()

        while time.time() - start_time < timeout:
            server = self.client.servers.get_by_name(server_name)
            if server and server.status == Server.STATUS_RUNNING:
                print(f"Server {server_name} is running!")
                return True
            elif server:
                print(f"Server status: {server.status}...")
            time.sleep(5)

        print(f"Timeout waiting for server {server_name}")
        return False

    def get_server_public_ip(self, server_name: str) -> Optional[str]:
        """Get the public IPv4 address of a server."""
        server = self.client.servers.get_by_name(server_name)
        if server and server.public_net:
            return server.public_net.ipv4.ip
        return None

    def execute_ssh_command(
        self,
        host: str,
        command: str,
        timeout: int = 300
    ) -> tuple[int, str, str]:
        """
        Execute a command via SSH.

        Args:
            host: Server IP address
            command: Command to execute
            timeout: Command timeout in seconds

        Returns:
            Tuple of (exit_code, stdout, stderr)
        """
        # Parse SSH key
        key_file = io.StringIO(self.ssh_key_content)
        ssh_key = paramiko.RSAKey.from_private_key(key_file)

        # Create SSH client
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        try:
            print(f"Connecting to {host}...")
            ssh.connect(
                hostname=host,
                username='root',
                pkey=ssh_key,
                timeout=30,
            )

            print(f"Executing: {command}")
            stdin, stdout, stderr = ssh.exec_command(
                command,
                timeout=timeout,
                get_pty=True
            )

            # Wait for command to complete
            exit_status = stdout.channel.recv_exit_status()

            stdout_text = stdout.read().decode('utf-8')
            stderr_text = stderr.read().decode('utf-8')

            return exit_status, stdout_text, stderr_text

        finally:
            ssh.close()

    def install_armbian_config(self, host: str) -> bool:
        """
        Install armbian-config on the server.

        Args:
            host: Server IP address

        Returns:
            True if successful, False otherwise
        """
        print(f"Installing armbian-config on {host}...")

        # Commands to install armbian-config
        commands = [
            # Update package list
            "apt-get update",
            # Install required dependencies
            "apt-get install -y curl git",
            # Install armbian-config
            "curl -s https://raw.githubusercontent.com/armbian/config/master/requirements.sh | bash",
        ]

        for cmd in commands:
            exit_code, stdout, stderr = self.execute_ssh_command(host, cmd, timeout=180)
            if exit_code != 0:
                print(f"Command failed: {cmd}")
                print(f"stderr: {stderr}")
                return False
            print(f"Command succeeded: {cmd}")

        print("armbian-config installed successfully!")
        return True

    def install_runner(self, host: str) -> bool:
        """
        Install GitHub Actions runner using armbian-config.

        Args:
            host: Server IP address

        Returns:
            True if successful, False otherwise
        """
        print(f"Installing GitHub Actions runner on {host}...")

        # Build the armbian-config command
        cmd = (
            f"armbian-config --api "
            f"module_armbian_runners "
            f"install "
            f"gh_token={self.github_token} "
            f"runner_name={self.runner_name} "
            f"start={self.start} "
            f"stop={self.stop} "
            f"label_primary={self.label_primary} "
            f"label_secondary={self.label_secondary} "
            f"organisation={self.organisation}"
        )

        exit_code, stdout, stderr = self.execute_ssh_command(host, cmd, timeout=600)

        if exit_code != 0:
            print(f"Runner installation failed!")
            print(f"stdout: {stdout}")
            print(f"stderr: {stderr}")
            return False

        print("Runner installed successfully!")
        print(f"Output: {stdout}")
        return True

    def deploy_server(
        self,
        machine_index: int,
        delete_existing: bool = False,
        install_runner: bool = True,
    ) -> Optional[Dict]:
        """
        Deploy a single server with GitHub Actions runner.

        Args:
            machine_index: Index into MACHINE_NAMES array
            delete_existing: Delete existing server if present
            install_runner: Whether to install the runner

        Returns:
            Dictionary with server info or None on failure
        """
        if machine_index < 0 or machine_index >= len(MACHINE_NAMES):
            print(f"Error: machine_index {machine_index} out of range (0-{len(MACHINE_NAMES)-1})")
            return None

        server_name = MACHINE_NAMES[machine_index]
        print(f"\n=== Deploying server: {server_name} ===")

        # Check if server exists
        if self.server_exists(server_name):
            if delete_existing:
                print(f"Server {server_name} already exists, deleting...")
                self.delete_server(server_name)
                time.sleep(5)  # Wait for deletion to complete
            else:
                print(f"Server {server_name} already exists. Use --delete-existing to replace it.")
                return None

        # Get SSH key
        ssh_key = self.get_ssh_key()
        if not ssh_key:
            print(f"Error: SSH key '{self.ssh_key_name}' not found in Hetzner!")
            return None

        print(f"Creating server {server_name}...")
        print(f"  Type: {self.machine_type}")
        print(f"  Image: {self.image_name}")
        print(f"  SSH Key: {ssh_key.name}")

        # Create server
        try:
            response = self.client.servers.create(
                name=server_name,
                server_type=ServerType(name=self.machine_type),
                image=Image(name=self.image_name),
                ssh_keys=[ssh_key],
            )

            # Wait for server to be created
            print(f"Waiting for server creation to complete...")
            response.action.wait(timeout=300)  # type: ignore
            print(f"Server {server_name} created!")

        except Exception as e:
            print(f"Error creating server: {e}")
            return None

        # Wait for server to be running
        if not self.wait_for_server_running(server_name):
            print("Server did not become running in time")
            return None

        # Get server IP
        server_ip = self.get_server_public_ip(server_name)
        if not server_ip:
            print("Could not get server IP")
            return None

        print(f"Server IP: {server_ip}")

        result = {
            "name": server_name,
            "index": machine_index,
            "ip": server_ip,
            "runner_installed": False,
        }

        # Install armbian-config and runner
        if install_runner:
            if self.install_armbian_config(server_ip):
                if self.install_runner(server_ip):
                    result["runner_installed"] = True
                else:
                    print("Runner installation failed!")
            else:
                print("armbian-config installation failed!")

        return result

    def delete_all_servers(self) -> int:
        """
        Delete all runner servers.

        Returns:
            Number of servers deleted
        """
        print("=== Deleting all runner servers ===")
        deleted = 0
        servers = self.client.servers.get_all()

        for server in servers:
            if server.name in MACHINE_NAMES:
                print(f"Deleting server: {server.name} (ID: {server.id})")
                self.client.servers.delete(server)
                deleted += 1

        print(f"Deleted {deleted} server(s)")
        return deleted


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Deploy Hetzner servers with GitHub Actions runners"
    )
    parser.add_argument(
        "action",
        choices=["enable", "disable", "deploy"],
        help="Action to perform"
    )
    parser.add_argument(
        "--hetzner-token",
        required=True,
        help="Hetzner Cloud API token (HCLOUD_TOKEN env var also works)"
    )
    parser.add_argument(
        "--github-token",
        required=True,
        help="GitHub personal access token (GITHUB_TOKEN env var also works)"
    )
    parser.add_argument(
        "--ssh-key",
        help="Path to SSH private key (SSH_KEY env var also works)"
    )
    parser.add_argument(
        "--ssh-key-name",
        default="TORRENT",
        help="Name of SSH key in Hetzner Cloud (default: TORRENT)"
    )
    parser.add_argument(
        "--machine-type",
        default="cax31",
        help="Hetzner server type (default: cax31)"
    )
    parser.add_argument(
        "--image",
        default="ubuntu-22.04",
        help="OS image name (default: ubuntu-22.04)"
    )
    parser.add_argument(
        "--machine-id",
        type=int,
        default=0,
        help="Machine ID/index (0-7, default: 0)"
    )
    parser.add_argument(
        "--machine-count",
        type=int,
        default=1,
        help="Number of machines to create (default: 1)"
    )
    parser.add_argument(
        "--delete-existing",
        action="store_true",
        help="Delete existing server before creating new one"
    )
    parser.add_argument(
        "--runner-name",
        default="runner",
        help="Base name for the runner (default: runner)"
    )
    parser.add_argument(
        "--start",
        type=int,
        default=1,
        help="Start hour for runner availability (default: 1)"
    )
    parser.add_argument(
        "--stop",
        type=int,
        default=24,
        help="Stop hour for runner availability (default: 24)"
    )
    parser.add_argument(
        "--label-primary",
        default="self-hosted",
        help="Primary runner labels (default: self-hosted)"
    )
    parser.add_argument(
        "--label-secondary",
        default="",
        help="Secondary runner labels (default: empty)"
    )
    parser.add_argument(
        "--organisation",
        default="",
        help="GitHub organization name"
    )
    parser.add_argument(
        "--output-json",
        action="store_true",
        help="Output results as JSON"
    )

    args = parser.parse_args()

    # Get tokens from args or environment
    hetzner_token = args.hetzner_token or os.environ.get("HCLOUD_TOKEN")
    github_token = args.github_token or os.environ.get("GITHUB_TOKEN")

    if not hetzner_token:
        print("Error: Hetzner token required (use --hetzner-token or HCLOUD_TOKEN env var)")
        sys.exit(1)

    if not github_token:
        print("Error: GitHub token required (use --github-token or GITHUB_TOKEN env var)")
        sys.exit(1)

    # Create deployer
    deployer = RunnerDeployer(
        hetzner_token=hetzner_token,
        github_token=github_token,
        ssh_key_path=args.ssh_key,
        ssh_key_name=args.ssh_key_name,
        machine_type=args.machine_type,
        image_name=args.image,
        runner_name=args.runner_name,
        start=args.start,
        stop=args.stop,
        label_primary=args.label_primary,
        label_secondary=args.label_secondary,
        organisation=args.organisation,
    )

    # Execute action
    if args.action == "disable":
        deleted = deployer.delete_all_servers()
        result = {"action": "disable", "deleted": deleted}
    else:  # enable or deploy
        results = []
        for i in range(args.machine_count):
            machine_id = args.machine_id + i
            if machine_id >= len(MACHINE_NAMES):
                print(f"Warning: machine_id {machine_id} exceeds available names (max: {len(MACHINE_NAMES)-1})")
                break

            result = deployer.deploy_server(
                machine_index=machine_id,
                delete_existing=args.delete_existing,
                install_runner=True,
            )
            if result:
                results.append(result)

        result = {
            "action": args.action,
            "servers": results,
        }

    # Output
    if args.output_json:
        print(json.dumps(result, indent=2))
    else:
        print(f"\n=== Result ===")
        print(json.dumps(result, indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())
