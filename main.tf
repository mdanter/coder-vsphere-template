terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    vsphere = {
      source  = "hashicorp/vsphere"
    }
  }
}

locals {
  username = data.coder_workspace_owner.me.name
}

# FIXED: Use parameters instead of hardcoded credentials
data "coder_parameter" "vsphere_user" {
  name         = "vsphere_user"
  display_name = "vSphere Username"
  description  = "vSphere administrator username"
  default      = "administrator@mdanter.lan"
  mutable      = false
  type         = "string"
  order        = 1
}

data "coder_parameter" "vsphere_password" {
  name         = "vsphere_password"
  display_name = "vSphere Password"
  description  = "vSphere administrator password"
  type         = "string"
  mutable      = false
  order        = 2
}

data "coder_parameter" "vsphere_server" {
  name         = "vsphere_server"
  display_name = "vSphere Server"
  description  = "vSphere server hostname or IP"
  default      = "vcenter.mdanter.lan"
  mutable      = false
  type         = "string"
  order        = 3
}

# FIXED: Make SSL verification configurable with secure default
data "coder_parameter" "allow_unverified_ssl" {
  name         = "allow_unverified_ssl"
  display_name = "Allow Unverified SSL"
  description  = "Allow unverified SSL certificates (not recommended for production)"
  type         = "bool"
  default      = "false"
  mutable      = false
  order        = 4
}

provider "vsphere" {
  user                 = data.coder_parameter.vsphere_user.value
  password             = data.coder_parameter.vsphere_password.value
  vsphere_server       = data.coder_parameter.vsphere_server.value
  allow_unverified_ssl = data.coder_parameter.allow_unverified_ssl.value
  api_timeout          = 10
}

data "vsphere_datacenter" "datacenter" {
  name = "sddc"
}

data "vsphere_datastore" "datastore" {
  name          = "nfs-gold"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = "dev-cluster"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_network" "network" {
  name          = "VM Network"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

data "vsphere_virtual_machine" "template" {
  name          = "coder-workspace"
  datacenter_id = data.vsphere_datacenter.datacenter.id
}

resource "vsphere_virtual_machine" "vm" {
  # FIXED: Include workspace name for multi-workspace support
  name             = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id
  # FIXED: Use CPU parameter instead of hardcoded value
  num_cpus         = data.coder_parameter.cpu_cores.value
  memory           = data.coder_parameter.memory.value
  guest_id         = "ubuntu64Guest"
  firmware         = data.vsphere_virtual_machine.template.firmware
  
  network_interface {
    network_id = data.vsphere_network.network.id
  }
  
  disk {
    label            = "Hard Disk 1"
    size             = data.vsphere_virtual_machine.template.disks.0.size
    thin_provisioned = data.vsphere_virtual_machine.template.disks.0.thin_provisioned
  }
  
  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    
    customize {
      linux_options {
        host_name = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
        domain    = "mdanter.lan"
      }
      
      network_interface {}
    }
  }
  
  # FIXED: Install Coder agent via cloud-init
  extra_config = {
    "guestinfo.userdata" = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      init_script = coder_agent.main.init_script
      username    = local.username
    }))
    "guestinfo.userdata.encoding" = "base64"
  }
}

# FIXED: Added CPU parameter for flexibility
data "coder_parameter" "cpu_cores" {
  name         = "cpu_cores"
  display_name = "CPU Cores"
  description  = "Number of CPU cores for the workspace"
  default      = "2"
  mutable      = true
  order        = 5
  
  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
  option {
    name  = "8 Cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "How much memory should your workspace use?"
  default      = "2048"
  mutable      = true
  order        = 6
  
  option {
    name  = "2 GB RAM"
    value = "2048"
  }
  option {
    name  = "4 GB RAM"
    value = "4096"
  }
  option {
    name  = "8 GB RAM"
    value = "8192"
  }
  option {
    name  = "16 GB RAM"
    value = "16384"
  }
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  
  # FIXED: Add connection timeout and troubleshooting URL
  connection_timeout  = 300
  troubleshooting_url = "https://coder.com/docs/templates/troubleshooting"
  
  # FIXED: Improved startup script with better error handling and logging
  startup_script = <<-EOT
    #!/bin/bash
    set -e

    # Log all output for debugging
    exec > >(tee -a /tmp/coder-startup.log)
    exec 2>&1

    echo "[$(date)] Starting Coder workspace initialization..."

    # Wait for cloud-init to complete
    if command -v cloud-init &> /dev/null; then
      echo "[$(date)] Waiting for cloud-init to complete..."
      sudo cloud-init status --wait || echo "cloud-init wait failed, continuing..."
    else
      echo "[$(date)] cloud-init not found, skipping..."
    fi

    # Prepare user home with default files on first start
    if [ ! -f ~/.init_done ]; then
      echo "[$(date)] Initializing user home directory..."
      cp -rT /etc/skel ~ 2>/dev/null || true
      touch ~/.init_done
      echo "[$(date)] User home initialized"
    fi

    # Install the latest code-server
    if ! command -v code-server &> /dev/null; then
      echo "[$(date)] Installing code-server..."
      if curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server; then
        echo "[$(date)] code-server installed successfully"
      else
        echo "[$(date)] ERROR: Failed to install code-server" >&2
        exit 1
      fi
    else
      echo "[$(date)] code-server already installed"
    fi

    # Start code-server in the background
    echo "[$(date)] Starting code-server on port 13337..."
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
    
    CODE_SERVER_PID=$!
    echo "[$(date)] code-server started with PID $CODE_SERVER_PID"
    
    # Wait a moment and verify it's still running
    sleep 2
    if kill -0 $CODE_SERVER_PID 2>/dev/null; then
      echo "[$(date)] code-server is running successfully"
    else
      echo "[$(date)] WARNING: code-server may have failed to start. Check /tmp/code-server.log" >&2
    fi

    echo "[$(date)] Workspace initialization complete!"
  EOT

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }

  metadata {
    display_name = "Swap Usage (Host)"
    key          = "7_swap_host"
    script       = <<EOT
      free -b | awk '/^Swap/ { printf("%.1f/%.1f", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'
    EOT
    interval     = 10
    timeout      = 1
  }
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  url          = "http://localhost:13337/?folder=/home/${local.username}"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 6
  }
}
