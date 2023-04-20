<p align="left"><img src="https://www.versio.io/img/supported-technology/hetzner-cloud.svg"></p
<h1>Hetzner runner deployments</h1>

## Usage

```yaml
- name: Enable Hetzner Virtual Machines
  uses: armbian/actions/hetzner@main
  with:
    action-type: enable # enable or disable VM cluster
    machine-type: cax21|cax31|... # machine type
    machine-id: 0,1,2 ... # selected machine
    runners-count: 1,2,3 # runners per machine
    machine-count: 1,2,3 # numbers of machines
    key: ${{ secrets.KEY_TORRENTS }} # key which we have in the Hezner API
    known_hosts: ${{ secrets.KNOWN_HOSTS_TORRENTS }}  # key_knowns_hosts which we have in the Hezner API
    hetzner_id: ${{ secrets.HETZNER_ONE }} # hetzner API token
    github_token: ${{ secrets.ACCESS_TOKEN }} # github action token

```
