## Usage

```yaml
      - name: Get releases
        uses: armbian/actions/make-json@main
        with:
          repository: "community"
          filename: "optimised"
          key: ${{ secrets.KEY_TORRENTS }}
          known_hosts: ${{ secrets.KNOWN_HOSTS_UPLOAD }}
          grep: "-v Uefi,Rpi4b"

```

repository = armbian/$repository

filename = its $repository if not defined

grep = [-v] key1,key2,... # -v = for excluding
