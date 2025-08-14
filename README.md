# Oracle Utilities C2M Linux Installer (Scaffold)

This repo provides a parameterized bash script and WLST helpers to automate a typical single-host C2M prerequisite setup on Linux with Oracle WebLogic. You must supply licensed vendor media (JDK, WebLogic, OUAF, C2M, DB installer) and a filled config.

## Files
- `install-c2m.sh`: main orchestrator script
- `c2m.env`: configuration template (edit this)
- `wlst/create_domain.py`: WLST offline domain creation
- `wlst/configure_datasource.py`: WLST offline JDBC DS setup
- `wlst/deploy_app.py`: WLST online deploy helper

## Quick start
1. Place vendor installers in a staging folder like `/u01/stage` and update paths in `c2m.env`:
   - `JDK_TARBALL`
   - `WLS_JAR`
   - (optional) `OUAF_INSTALLER`, `OUAF_RESPONSE_FILE`, `C2M_INSTALLER`, `C2M_RESPONSE_FILE`, `DB_INSTALLER`, `DB_INSTALLER_RESPONSE`, `PRODUCT_EAR`
2. Review toggles in `c2m.env` and set to `true` the steps you want to run.
3. Run as root (sudo):

```bash
sudo bash /workspace/install-c2m.sh /workspace/c2m.env
```

- Domain creation is offline. Datasource config is offline. To deploy the EAR, ensure AdminServer is running and enable `DEPLOY_APP=true`.

## Notes
- This is a scaffold. Exact silent install options and response files depend on your specific OUAF/C2M versions and licensing.
- Admin user is fixed to `weblogic` for offline domain creation.
- JDBC URL uses `jdbc:oracle:thin:@//<host>:<port>/<service>`; adjust in `c2m.env` if needed.
- For production, secure passwords and rotate them after provisioning.