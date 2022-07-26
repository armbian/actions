## Usage

```yaml
- name: "Build images"
    id: build-images
    uses: armbian/actions/build-images@main
    with:
        choice: "beta|stable|rc"
        runner: "ubuntu-latest|small|big"
        sourcerepo: "nightly"
        packagesrepo: "*yes*|no"
        advanced: "grep -w tinkerboard |"
        
```
