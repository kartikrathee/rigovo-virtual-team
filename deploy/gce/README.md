# Google Compute Engine deployment

This setup runs the FastAPI control plane as a single-user service on a Debian
VM. SQLite and control-plane state live on the persistent boot disk under
`/srv/rigovo/workspace/.rigovo`.

The API binds to `127.0.0.1:8787`. The intended client connection is an IAP SSH
port forward, so the API port is never opened in the VPC firewall. The VM needs
an ephemeral external address only for outbound package and LLM API traffic;
the firewall allows inbound SSH from IAP's `35.235.240.0/20` range only.

## Runtime overview

- `rigovo serve` starts the FastAPI control plane.
- LangGraph runs task orchestration inside the API process.
- SQLite stores task history, audit records, costs, settings, and memory.
- The default workspace is `/srv/rigovo/workspace`.
- LLM provider keys are configured from the desktop Settings page and stored
  in the workspace database encrypted with Rigovo's Fernet settings store.
- The Electron app can connect to the local end of the SSH tunnel at
  `http://127.0.0.1:8787`.

## VM startup

`startup.sh` installs Python, Node.js 20, and the pinned Python dependencies,
then creates and enables `rigovo.service`. It also registers the default VM
workspace once. Re-run it to refresh packages and recreate the service file;
the SQLite database and workspace files remain on the boot disk.

## Connect from the desktop

Start a tunnel in a terminal and leave it running:

```bash
gcloud compute ssh rigovo-vm \
  --project=rigovo-vteam-krt-20261014 \
  --zone=asia-south1-a \
  --tunnel-through-iap \
  -- -N -L 8787:127.0.0.1:8787
```

Then launch the Rigovo desktop app. It uses `http://127.0.0.1:8787` by
default and will connect to the VM through the tunnel. Keep the tunnel open
while using the app.

## Workspace operations

The default workspace is on the VM, so local paths chosen in Electron are not
valid remote paths. Clone or upload target repositories into
`/srv/rigovo/workspace` over IAP SSH, then register a path on the VM through the
UI's path prompt (when using the browser renderer) or the API:

```bash
curl -X POST http://127.0.0.1:8787/v1/projects \
  -H 'Content-Type: application/json' \
  -d '{"path":"/srv/rigovo/workspace/my-repo"}'
```

This deployment is for one trusted operator. The API currently has no
request-auth middleware, so do not expose port 8787 publicly or put it behind a
public proxy without adding backend authentication first.
