# Check fixtures

`user_credentials.json` here is a **throwaway placeholder** used only by
Tier 3 (`archinstall --dry-run`) and Tier 4 (a real archinstall into a
disposable loopback file inside a container). Both need *some* credentials
file to exercise archinstall's auth parsing; neither installs anything you
will ever log into.

Its hash is a sha512crypt of the publicly-known string
`ChangeMe-ArchProject!1`. That is fine precisely because this file never
ships: the real ISO's credentials are generated at build time from a
password you type into `iso/build-iso.ps1`, written straight into the build
container's profile, and never written back into this repo (the path it
lands on is gitignored).

Do not point any real install flow at this file.
