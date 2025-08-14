# test

## CI/CD deployment (GitHub Actions)

This repo includes a generic deployment pipeline:
- On push to `main` or manual trigger, it syncs the repo to your server over SSH and runs `scripts/deploy.sh` remotely.
- The remote script supports either Docker Compose (set `USE_DOCKER=true`) or restarting a `systemd` service (set `SERVICE_NAME`).

### Setup
1. In your repo settings, add the following secrets:
   - `SSH_HOST`: server host (e.g., `example.com`)
   - `SSH_USER`: SSH username
   - `SSH_PRIVATE_KEY`: private key contents (ed25519 or rsa)
   - `DEPLOY_PATH`: absolute path on the server (e.g., `/var/www/myapp`)
   - `SERVICE_NAME` (optional): systemd unit to restart (e.g., `myapp.service`)
   - `USE_DOCKER` (optional): set to `true` to use Docker Compose deployment
2. Ensure the SSH key is authorized on the server and that the user can `sudo systemctl restart` the service (or Docker is installed for Docker deployments).
3. Push to `main` or run the "Deploy" workflow from the Actions tab.

### Notes
- Files `.git` and `.github` are excluded from sync.
- If `package.json` exists, the script runs `npm ci` and optional `npm run build`.
- If `requirements.txt` exists, it sets up a `.venv` and installs dependencies.
- For Docker, a `docker-compose.yml`/`compose.yml` is expected.