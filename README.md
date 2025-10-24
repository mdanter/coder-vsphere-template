# vSphere Coder Template - Security Improvements

## ✅ Fixed Issues

### 1. Removed Hardcoded Credentials (Security)
**Before:** Credentials were hardcoded in the template  
**After:** Credentials are now template parameters

When creating/updating the template, you'll be prompted for:
- vSphere Username (default: `administrator@mdanter.lan`)
- vSphere Password (no default, required)
- vSphere Server (default: `vcenter.mdanter.lan`)

**Best Practice:** For production, use environment variables instead:
```bash
export TF_VAR_vsphere_user="administrator@mydomain.com"
export TF_VAR_vsphere_password="secure-password"
export TF_VAR_vsphere_server="vcenter.mydomain.com"
```

Then modify the template to use `var.vsphere_user` instead of parameters.

### 2. Fixed SSL Verification (Security)
**Before:** `allow_unverified_ssl = true` (insecure)  
**After:** Configurable parameter with secure default (`false`)

**Recommendation:** 
- For production: Keep `false` and install proper SSL certificates on vCenter
- For dev/test only: Can set to `true` if needed

### 3. Added Coder Agent Installation (Functionality)
**Before:** Agent init script was not being executed on the VM  
**After:** Agent is installed via cloud-init using `guestinfo.userdata`

### 4. Added CPU Parameter (Flexibility)
**Before:** CPU cores hardcoded to `1`  
**After:** Configurable CPU parameter with options for 2, 4, or 8 cores
- Default: 2 cores
- Mutable: Yes (can be changed after workspace creation)
- Also updated memory parameter to be mutable with more options (2GB, 4GB, 8GB, 16GB)

### 5. Fixed Workspace Naming (Multi-Workspace Support)
**Before:** `workspace-${username}` - Only supports one workspace per user  
**After:** `coder-${username}-${workspace_name}` - Supports multiple workspaces per user

**Benefits:**
- Users can create multiple workspaces with different names
- No VM name conflicts
- Easier to identify workspaces in vCenter
- Hostname also updated to match

### 6. Improved Startup Script (Reliability)
**Before:** Basic script with minimal error handling  
**After:** Production-ready script with:
- Timestamped logging to `/tmp/coder-startup.log`
- Proper error handling and status messages
- Verification that code-server actually started
- Better cloud-init integration
- Idempotent (safe to run multiple times)

**Requirements:**
- Your `coder-workspace` template VM must have `cloud-init` installed
- The VM must support `guestinfo.userdata` (most modern Linux distributions do)
- VMware Tools or open-vm-tools must be installed on the template

## 📋 Migration Steps

1. **Backup your current template:**
   ```bash
   coder templates pull <template-name> ./backup
   ```

2. **Ensure your VM template has cloud-init:**
   ```bash
   # On your coder-workspace template VM:
   sudo apt-get update
   sudo apt-get install -y cloud-init
   sudo systemctl enable cloud-init
   ```

3. **Update the template:**
   ```bash
   coder templates push <template-name> -d .
   ```

4. **When prompted, enter your vSphere credentials**

5. **Set SSL verification:**
   - Production: Leave default (`false`)
   - Dev/Test with self-signed certs: Set to `true`

## 🔐 Security Best Practices

### Option 1: Admin-Only Parameters (Recommended)
To hide credentials from regular users, make them admin-only:

```terraform
data "coder_parameter" "vsphere_password" {
  name         = "vsphere_password"
  display_name = "vSphere Password"
  type         = "string"
  mutable      = false
  admin        = true  # Only template admins can see/edit
}
```

### Option 2: Environment Variables (Most Secure)
Use Terraform variables and set them in your Coder deployment:

```terraform
variable "vsphere_user" {
  type      = string
  sensitive = true
}

variable "vsphere_password" {
  type      = string
  sensitive = true
}

provider "vsphere" {
  user     = var.vsphere_user
  password = var.vsphere_password
  # ...
}
```

Then configure in your Coder deployment:
```bash
export CODER_PROVISIONER_DAEMON_ENV="TF_VAR_vsphere_user=admin@domain.com,TF_VAR_vsphere_password=secret"
```

### Option 3: HashiCorp Vault (Enterprise)
Integrate with Vault for credential management:
```terraform
data "vault_generic_secret" "vsphere" {
  path = "secret/vsphere"
}

provider "vsphere" {
  user     = data.vault_generic_secret.vsphere.data["username"]
  password = data.vault_generic_secret.vsphere.data["password"]
  # ...
}
```

## 🧪 Testing

After updating the template:

1. **Create a test workspace:**
   ```bash
   coder create test-workspace --template=<template-name>
   ```

2. **Verify agent connection:**
   ```bash
   coder ssh test-workspace
   ```

3. **Check code-server is running:**
   ```bash
   coder open test-workspace
   ```

4. **View agent logs if issues occur:**
   ```bash
   coder ssh test-workspace
   sudo journalctl -u cloud-init -f
   cat /var/log/cloud-init-output.log
   ```

## 📝 Files

- `main.tf` - Main Terraform configuration with security fixes
- `cloud-init.yaml` - Cloud-init template for agent installation
- `README.md` - This file

## 🆘 Troubleshooting

### Agent doesn't connect
1. Check cloud-init is installed on template VM
2. Verify VMware Tools is installed
3. Check cloud-init logs: `sudo cat /var/log/cloud-init-output.log`
4. Verify init script ran: `sudo cloud-init status`
5. Check startup logs: `cat /tmp/coder-startup.log`
6. Verify agent is running: `ps aux | grep coder_agent`

### code-server not accessible
1. Check if it's running: `ps aux | grep code-server`
2. Check code-server logs: `cat /tmp/code-server.log`
3. Check startup logs: `cat /tmp/coder-startup.log`
4. Verify port 13337 is listening: `ss -tlnp | grep 13337`

### VM name conflicts
- If you see "VM already exists" errors, a workspace with that name already exists
- Delete the old workspace or choose a different workspace name
- New naming format prevents conflicts: `coder-username-workspacename`

### SSL certificate errors
- If using self-signed certs, set `allow_unverified_ssl` to `true`
- For production, install valid certificates on vCenter

### Permission denied errors
- Verify vSphere credentials have permission to:
  - Clone VMs
  - Modify VM settings
  - Access specified datastore and network
  - Set guestinfo properties (for cloud-init)

### CPU/Memory changes not applying
- CPU and memory are now mutable parameters
- Stop the workspace, update parameters via `coder update`, then restart
- Changes require a workspace restart to take effect
