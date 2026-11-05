# Deploying the shared service

The files here run `zemi --shared` on a Debian or Ubuntu server: `install.sh` installs it under
systemd (`zemi.service`) with Caddy in front (`Caddyfile`, and `down/` for the page Caddy shows
while the service is down).

Setup, installation and operation are in the guide:
[Server deployment](https://kahliburke.github.io/Zemi.jl/deployment).

```
sudo /srv/zemi/Zemi.jl/deploy/install.sh kb.example.org [name]
```
